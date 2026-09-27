#!/usr/bin/env ruby
require 'yaml'

workflow = YAML.load_file(File.join(__dir__, 'ci.yml'))
release = YAML.load_file(File.join(__dir__, 'release.yml'))
triggers = workflow['on'] || workflow[true]
jobs = workflow.fetch('jobs')
prepare = jobs.fetch('prepare-pr-source')
checks = jobs.fetch('test')
gate_names = %w[fmt clippy cargo-test doc package]
gates = gate_names.to_h { |name| [name, jobs.fetch(name)] }

assert = ->(condition, message) { abort message unless condition }
includes = ->(value, part, message) { assert.call(value.to_s.include?(part), message) }

assert.call(triggers.key?('pull_request_target'), 'CI must use the base-controlled pull_request_target event')
assert.call(!triggers.key?('pull_request'), 'CI must not load a public PR workflow definition')
assert.call(workflow.fetch('permissions') == { 'contents' => 'read' }, 'pull_request_target token must be read-only')
assert.call(triggers.key?('workflow_dispatch'), 'CI manual trigger was removed')
assert.call(triggers.dig('push', 'branches') == ['main'], 'main push trigger changed')
assert.call(prepare['if'] == "github.event_name == 'pull_request_target'", 'source preparation must be PR-only')
assert.call(prepare['runs-on'] == 'ubuntu-latest', 'public PR source preparation must use GitHub-hosted runners')
assert.call(checks['needs'] == ['prepare-pr-source', *gate_names], 'required check must depend on preparation and every gate')
includes.call(checks['if'], 'always()', 'required check must run after cancellation')
includes.call(checks.dig('steps', 0, 'run'), 'Required workflow gate did not succeed', 'required check must fail when a gate fails')
assert.call(workflow.dig('concurrency', 'group') == 'crispy-catchup-pr-${{ github.event.pull_request.number || github.ref }}', 'workflow concurrency must be PR scoped')
assert.call(workflow.dig('concurrency', 'cancel-in-progress') == false, 'workflow must not cancel an in-progress PR run')

trusted_runner = "${{ (github.event_name == 'pull_request_target' && 'ubuntu-latest') || (github.ref == 'refs/heads/main' && github.actor == github.repository_owner && fromJSON('[\"self-hosted\",\"linux\",\"x64\",\"generic\"]')) || 'ubuntu-latest' }}"
artifact_name = 'pr-source-${{ github.repository_id }}-${{ github.event.pull_request.number }}-${{ github.run_id }}-${{ github.run_attempt }}'
[checks, *gates.values].each do |job|
  assert.call(job.fetch('runs-on') == trusted_runner, 'PR jobs may use self-hosted runners only for owner runs from main')
end
[
  { event: 'pull_request_target', ref: 'refs/heads/main', actor: 'moabualruz', expected: 'ubuntu-latest' },
  { event: 'pull_request_target', ref: 'refs/heads/main', actor: 'contributor', expected: 'ubuntu-latest' },
  { event: 'push', ref: 'refs/heads/main', actor: 'moabualruz', expected: 'self-hosted' },
  { event: 'push', ref: 'refs/heads/main', actor: 'contributor', expected: 'ubuntu-latest' },
  { event: 'workflow_dispatch', ref: 'refs/heads/main', actor: 'moabualruz', expected: 'self-hosted' },
  { event: 'workflow_dispatch', ref: 'refs/heads/feature', actor: 'moabualruz', expected: 'ubuntu-latest' }
].each do |scenario|
  hosted = scenario[:event] == 'pull_request_target' || scenario[:ref] != 'refs/heads/main' || scenario[:actor] != 'moabualruz'
  actual = hosted ? 'ubuntu-latest' : 'self-hosted'
  assert.call(actual == scenario[:expected], "unexpected runner for #{scenario[:event]} by #{scenario[:actor]} on #{scenario[:ref]}")
end
jobs.each do |name, job|
  assert.call(!job.key?('group'), "job #{name} must not require a custom runner group")
end
targets = gates.map do |name, job|
  assert.call(job['needs'] == 'prepare-pr-source', "#{name} must wait only for preparation")
  includes.call(job['if'], '!cancelled()', "#{name} must stop on cancellation")
  includes.call(job['if'], "needs.prepare-pr-source.result == 'success'", "#{name} must require successful PR preparation")
  includes.call(job['if'], "needs.prepare-pr-source.result == 'skipped'", "#{name} must allow non-PR runs")
  target_step = job.dig('steps', 0)
  assert.call(target_step && target_step['name'] == 'Isolate this gate build output', "#{name} must isolate Cargo output before running")
  target = target_step['run']
  includes.call(target, '$RUNNER_TEMP', "#{name} target must use RUNNER_TEMP")
  includes.call(target, '%s/cargo-target/', "#{name} target path must be under RUNNER_TEMP")
  target_suffix = name == 'cargo-test' ? '-test' : "-#{name}"
  includes.call(target, target_suffix, "#{name} target directory must be unique")
  includes.call(target, '$GITHUB_RUN_ID', "#{name} target must include the workflow run")
  includes.call(target, '$GITHUB_RUN_ATTEMPT', "#{name} target must include the run attempt")
  target
end
assert.call(targets.uniq.length == gate_names.length, 'Cargo gates must not share target directories')
gate_names.each do |name|
  steps = gates.fetch(name).fetch('steps')
  assert.call(steps.none? { |step| step['name'] == 'Verify shared PR worktree' }, "#{name} must not access a shared self-hosted PR worktree")
  checkout = steps.find { |step| step['uses'] == 'actions/checkout@v4' }
  assert.call(checkout && checkout['if'] == "github.event_name != 'pull_request_target'", "#{name} must not check out PR source independently")
  download = steps.find { |step| step['uses'] == 'actions/download-artifact@v4' }
  assert.call(download && download['if'] == "github.event_name == 'pull_request_target'", "#{name} must restore the one prepared PR source")
  assert.call(download.dig('with', 'name') == artifact_name, "#{name} must use the prepared source artifact")
  restore = steps.find { |step| step['name'] == 'Restore prepared PR source' }
  assert.call(restore && restore['if'] == "github.event_name == 'pull_request_target'", "#{name} must extract the prepared PR source")
end

prep_steps = prepare.fetch('steps')
pr_checkout = prep_steps.find { |step| step['uses'] == 'actions/checkout@v4' }
assert.call(pr_checkout && pr_checkout['if'].nil?, 'all PR source must be checked out once in preparation')
assert.call(prep_steps.count { |step| step['uses'] == 'actions/checkout@v4' } == 1, 'prepare must check out source exactly once')
assert.call(pr_checkout.dig('with', 'ref') == '${{ github.event.pull_request.head.sha }}', 'PR checkout must pin the event head SHA')
assert.call(pr_checkout.dig('with', 'persist-credentials') == false, 'PR checkout must not persist credentials')
verify_sha = prep_steps.find { |step| step['name'] == 'Verify PR event source SHA' }
assert.call(verify_sha && verify_sha.dig('env', 'EXPECTED_PR_HEAD_SHA') == '${{ github.event.pull_request.head.sha }}', 'PR source verification must use the event head SHA')
includes.call(verify_sha.dig('run'), 'git rev-parse HEAD', 'PR source verification must inspect the checked out commit')
includes.call(verify_sha.dig('run'), 'EXPECTED_PR_HEAD_SHA', 'PR source verification must compare against the event head SHA')
assert.call(prep_steps.none? { |step| step['run'] == 'ruby .github/workflows/test_ci_workflow.rb' }, 'pull_request_target must not execute a test script from untrusted PR source')
assert.call(prep_steps.any? { |step| step['run'].to_s.include?('cargo fetch') }, 'dependencies must be prepared serially')
archive = prep_steps.find { |step| step['name'] == 'Archive prepared PR source' }
assert.call(archive && archive['if'].nil?, 'PR source archive must include every pull request')
includes.call(archive.dig('run'), 'git archive --format=tar HEAD', 'PR archive must use the checked out merge ref')
includes.call(archive.dig('run'), 'Cargo.lock', 'generated Cargo.lock must travel with the prepared source')
upload = prep_steps.find { |step| step['uses'] == 'actions/upload-artifact@v4' }
assert.call(upload && upload['if'].nil? && upload.dig('with', 'name') == artifact_name, 'prepared PR source artifact missing')
assert.call(prep_steps.count { |step| step['uses'] == 'actions/upload-artifact@v4' } == 1, 'prepare must upload exactly one source snapshot')
%w[github.repository_id github.event.pull_request.number github.run_id github.run_attempt].each do |field|
  includes.call(artifact_name, field, "fork artifact name must include #{field}")
end

archive_name = gates.fetch('cargo-test').dig('steps')&.find { |step| step['name'] == 'Restore prepared PR source' }
assert.call(archive_name, 'prepared PR source extraction missing from a cargo gate')
gate_commands = {
  'fmt' => 'cargo fmt --check',
  'clippy' => 'cargo clippy --all-targets --all-features -- -D warnings',
  'cargo-test' => 'cargo test --all-features',
  'doc' => 'cargo doc --no-deps',
  'package' => 'cargo package'
}
gate_commands.each do |name, command|
  assert.call(gates.fetch(name).dig('steps')&.any? { |step| step['run'] == command }, "#{name} must execute #{command}")
end
%w[PREPARE_RESULT FMT_RESULT CLIPPY_RESULT TEST_RESULT DOC_RESULT PACKAGE_RESULT].each do |result|
  includes.call(checks.dig('steps', 0, 'env', result), "needs.", "required check must inspect #{result}")
end

release_triggers = release['on'] || release[true]
assert.call(release_triggers.key?('workflow_dispatch'), 'manual release trigger was removed')
assert.call(release.fetch('permissions') == { 'contents' => 'read' }, 'manual release token must be read-only')
assert.call(release_triggers.dig('workflow_dispatch', 'inputs', 'version', 'required'), 'manual release version input changed')
release_job = release.fetch('jobs').fetch('release-check')
assert.call(release_job.fetch('runs-on') == "${{ github.ref == 'refs/heads/main' && github.actor == github.repository_owner && fromJSON('[\"self-hosted\", \"linux\", \"x64\", \"generic\"]') || 'ubuntu-latest' }}", 'release self-hosted runner must require owner dispatch from main')
release_checkout = release_job.fetch('steps').find { |step| step['uses'] == 'actions/checkout@v4' }
assert.call(release_checkout&.dig('with', 'persist-credentials') == false, 'manual release checkout must not persist credentials')
require 'tmpdir'
require 'open3'

def capture(*args, chdir: nil, env: {})
  options = chdir ? { chdir: chdir } : {}
  Open3.capture2e(env, *args, **options)
end

def run!(*args, chdir: nil, env: {})
  output, status = capture(*args, chdir: chdir, env: env)
  abort output unless status.success?
  output
end

summary_command = checks.dig('steps', 0, 'run')
summary_env = {
  'GITHUB_EVENT_NAME' => 'push',
  'PREPARE_RESULT' => 'skipped',
  'FMT_RESULT' => 'success',
  'CLIPPY_RESULT' => 'success',
  'TEST_RESULT' => 'success',
  'DOC_RESULT' => 'success',
  'PACKAGE_RESULT' => 'success'
}
run!('bash', '-e', '-o', 'pipefail', '-c', summary_command, env: summary_env)
%w[FMT_RESULT CLIPPY_RESULT TEST_RESULT DOC_RESULT PACKAGE_RESULT].each do |failed_gate|
  _, status = Open3.capture2e(summary_env.merge(failed_gate => 'failure'), 'bash', '-e', '-o', 'pipefail', '-c', summary_command)
  assert.call(!status.success?, "required check must fail when #{failed_gate} fails")
end
_, status = Open3.capture2e(summary_env.merge('GITHUB_EVENT_NAME' => 'pull_request_target'), 'bash', '-e', '-o', 'pipefail', '-c', summary_command)
assert.call(!status.success?, 'required check must fail when PR preparation is skipped')

Dir.mktmpdir('ci-source-contract') do |temp|
  repo = File.join(temp, 'repo')
  Dir.mkdir(repo)
  run!('git', 'init', '-q', '-b', 'base', repo)
  run!('git', '-C', repo, 'config', 'user.email', 'workflow-test@example.invalid')
  run!('git', '-C', repo, 'config', 'user.name', 'Workflow Test')
  File.write(File.join(repo, 'source.txt'), 'base source')
  run!('git', '-C', repo, 'add', 'source.txt')
  run!('git', '-C', repo, 'commit', '-qm', 'base fixture')
  run!('git', '-C', repo, 'switch', '-c', 'pr-head')
  File.write(File.join(repo, 'source.txt'), 'PR head bytes')
  run!('git', '-C', repo, 'commit', '-qam', 'PR head')
  pr_head_sha = run!('git', '-C', repo, 'rev-parse', 'HEAD').strip
  run!('git', '-C', repo, 'switch', '-c', 'later-pr-head')
  File.write(File.join(repo, 'source.txt'), 'later PR head bytes')
  run!('git', '-C', repo, 'commit', '-qam', 'later PR head')
  later_pr_head_sha = run!('git', '-C', repo, 'rev-parse', 'HEAD').strip
  run!('git', '-C', repo, 'update-ref', 'refs/pull/2/merge', later_pr_head_sha)
  assert.call(pr_head_sha != later_pr_head_sha, 'fixture must include a later mutable PR ref target')
  run!('git', '-C', repo, 'checkout', '--detach', pr_head_sha)
  File.write(File.join(repo, 'source.txt'), 'working tree poison')
  File.write(File.join(repo, 'untracked.txt'), 'must not be archived')
  File.write(File.join(repo, 'Cargo.lock'), 'generated lock bytes')

  runner_temp = File.join(temp, 'runner-temp')
  Dir.mkdir(runner_temp)
  verify_sha_command = verify_sha.fetch('run')
  run!('bash', '-e', '-o', 'pipefail', '-c', verify_sha_command, chdir: repo, env: { 'EXPECTED_PR_HEAD_SHA' => pr_head_sha })
  archive_command = prepare.fetch('steps').find { |step| step['name'] == 'Archive prepared PR source' }.fetch('run')
  run!('bash', '-e', '-o', 'pipefail', '-c', archive_command, chdir: repo, env: { 'RUNNER_TEMP' => runner_temp })

  run!('git', '-C', repo, 'checkout', '--', 'source.txt')
  run!('git', '-C', repo, 'checkout', '--detach', later_pr_head_sha)
  _, drift_status = capture('bash', '-e', '-o', 'pipefail', '-c', verify_sha_command, chdir: repo, env: { 'EXPECTED_PR_HEAD_SHA' => pr_head_sha })
  assert.call(!drift_status.success?, 'PR source verification must reject a ref that moved after the event snapshot')

  workspace = File.join(temp, 'downstream')
  Dir.mkdir(workspace)
  restore_command = gates.fetch('cargo-test').fetch('steps').find { |step| step['name'] == 'Restore prepared PR source' }.fetch('run')
  run!('bash', '-e', '-c', restore_command, env: { 'RUNNER_TEMP' => runner_temp, 'GITHUB_WORKSPACE' => workspace })
  assert.call(File.read(File.join(workspace, 'source.txt')) == 'PR head bytes', 'PR source archive did not restore the event head snapshot')
  assert.call(File.read(File.join(workspace, 'Cargo.lock')) == 'generated lock bytes', 'PR source artifact omitted generated Cargo.lock')
  assert.call(!File.exist?(File.join(workspace, '.git')), 'PR source artifact must not carry Git credentials or metadata')
  assert.call(!File.exist?(File.join(workspace, 'untracked.txt')), 'PR source artifact included unrelated untracked content')
end

puts 'CI workflow route contract passed'
