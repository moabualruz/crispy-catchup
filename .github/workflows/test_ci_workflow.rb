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

assert.call(triggers.key?('pull_request'), 'CI must run for pull requests')
assert.call(triggers.key?('workflow_dispatch'), 'CI manual trigger was removed')
assert.call(triggers.dig('push', 'branches') == ['main'], 'main push trigger changed')
assert.call(prepare['if'] == "github.event_name == 'pull_request'", 'source preparation must be PR-only')
assert.call(checks['needs'] == ['prepare-pr-source', *gate_names], 'required check must depend on preparation and every gate')
includes.call(checks['if'], 'always()', 'required check must run after cancellation')
includes.call(checks.dig('steps', 0, 'run'), 'Required workflow gate did not succeed', 'required check must fail when a gate fails')
assert.call(workflow.dig('concurrency', 'group') == 'crispy-catchup-pr-${{ github.event.pull_request.number || github.ref }}', 'workflow concurrency must be PR scoped')
assert.call(workflow.dig('concurrency', 'cancel-in-progress') == false, 'workflow must not cancel a run while its PR worktree is in use')

prepare_route = prepare.fetch('runs-on')
checks_route = checks.fetch('runs-on')
[prepare_route, checks_route, *gates.values.map { |job| job.fetch('runs-on') }].each do |route|
  includes.call(route, '["self-hosted","linux","x64","generic","pr-{0}-{1}"]', 'trusted PR route must require stable per-PR labels')
  includes.call(route, 'github.event.pull_request.head.repo.full_name == github.repository', 'same-repo PR route missing')
  includes.call(route, 'ubuntu-latest', 'fork PR route must use GitHub-hosted runners')
  includes.call(route, 'pr-{0}-{1}', 'PR runner label must include repository and PR')
  assert.call(!route.to_s.include?('run-{2}-attempt-{3}'), 'PR runner label must not be run scoped')
  assert.call(!route.to_s.include?('group'), 'runner route must not require a custom runner group')
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
  source_check = steps.find { |step| step['name'] == 'Verify shared PR worktree' }
  assert.call(source_check && source_check['if'] == "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository", "#{name} must verify only same-repository PR worktrees")
  includes.call(source_check.dig('env', 'EXPECTED_SHA'), '${{ github.sha }}', "#{name} must pin its worktree check to the event SHA")
  includes.call(source_check.dig('run'), 'test -L "$GITHUB_WORKSPACE"', "#{name} must require the brokered worktree symlink")
  includes.call(source_check.dig('run'), 'rev-parse --show-toplevel', "#{name} must reject a workspace below the worktree root")
  includes.call(source_check.dig('run'), 'rev-parse HEAD', "#{name} must verify the prepared revision")
  checkout = steps.find { |step| step['uses'] == 'actions/checkout@v4' }
  assert.call(checkout && checkout['if'] == "github.event_name != 'pull_request'", "#{name} must not check out PR source independently")
  download = steps.find { |step| step['uses'] == 'actions/download-artifact@v4' }
  assert.call(download && download['if'].include?('head.repo.full_name != github.repository'), "#{name} must restore only prepared fork source")
  restore = steps.find { |step| step['name'] == 'Restore fork source' }
  assert.call(restore && restore['if'].include?('head.repo.full_name != github.repository'), "#{name} must extract prepared fork source")
end

prep_steps = prepare.fetch('steps')
fork_checkout = prep_steps.find { |step| step['uses'] == 'actions/checkout@v4' }
assert.call(fork_checkout && fork_checkout['if'].include?('head.repo.full_name != github.repository'), 'only fork preparation may check out source')
assert.call(fork_checkout.dig('with', 'persist-credentials') == false, 'fork checkout must not persist credentials')
assert.call(prep_steps.any? { |step| step['run'].to_s.include?('cargo fetch --locked') }, 'dependencies must be prepared serially')
assert.call(prep_steps.any? { |step| step['run'] == 'ruby .github/workflows/test_ci_workflow.rb' }, 'workflow contract must run in preparation')
archive = prep_steps.find { |step| step['name'] == 'Archive fork source' }
assert.call(archive && archive['if'].include?('head.repo.full_name != github.repository'), 'fork source archive missing')
upload = prep_steps.find { |step| step['uses'] == 'actions/upload-artifact@v4' }
assert.call(upload && upload['if'].include?('head.repo.full_name != github.repository'), 'fork source artifact missing')
artifact_name = upload.dig('with', 'name')
%w[github.repository_id github.event.pull_request.number github.run_id github.run_attempt].each do |field|
  includes.call(artifact_name, field, "fork artifact name must include #{field}")
end

archive_name = gates.fetch('cargo-test').dig('steps')&.find { |step| step['name'] == 'Restore fork source' }
assert.call(archive_name, 'fork source extraction missing from a cargo gate')
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
assert.call(release_triggers.dig('workflow_dispatch', 'inputs', 'version', 'required'), 'manual release version input changed')
release_job = release.fetch('jobs').fetch('release-check')
release_checkout = release_job.fetch('steps').find { |step| step['uses'] == 'actions/checkout@v4' }
assert.call(release_checkout&.dig('with', 'persist-credentials') == false, 'manual release checkout must not persist credentials')
require 'tmpdir'
require 'open3'

def run!(*args, chdir: nil, env: {})
  options = chdir ? { chdir: chdir } : {}
  output, status = Open3.capture2e(env, *args, **options)
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
_, status = Open3.capture2e(summary_env.merge('GITHUB_EVENT_NAME' => 'pull_request'), 'bash', '-e', '-o', 'pipefail', '-c', summary_command)
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
  run!('git', '-C', repo, 'switch', 'base')
  File.write(File.join(repo, 'base-context.txt'), 'merge base context')
  run!('git', '-C', repo, 'add', 'base-context.txt')
  run!('git', '-C', repo, 'commit', '-qm', 'base context')
  run!('git', '-C', repo, 'merge', '--no-ff', '-m', 'merge PR source', 'pr-head')
  merge_sha = run!('git', '-C', repo, 'rev-parse', 'HEAD').strip
  assert.call(pr_head_sha != merge_sha, 'fixture PR head and merge commit must differ')
  run!('git', '-C', repo, 'switch', 'pr-head')
  File.write(File.join(repo, 'source.txt'), 'working tree poison')
  File.write(File.join(repo, 'untracked.txt'), 'must not be archived')

  runner_temp = File.join(temp, 'runner-temp')
  Dir.mkdir(runner_temp)
  archive_command = prepare.fetch('steps').find { |step| step['name'] == 'Archive fork source' }.fetch('run')
  run!('bash', '-e', '-o', 'pipefail', '-c', archive_command, chdir: repo, env: { 'GITHUB_SHA' => merge_sha, 'RUNNER_TEMP' => runner_temp })

  workspace = File.join(temp, 'downstream')
  Dir.mkdir(workspace)
  restore_command = gates.fetch('cargo-test').fetch('steps').find { |step| step['name'] == 'Restore fork source' }.fetch('run')
  run!('bash', '-e', '-c', restore_command, env: { 'RUNNER_TEMP' => runner_temp, 'GITHUB_WORKSPACE' => workspace })
  assert.call(File.read(File.join(workspace, 'source.txt')) == 'PR head bytes', 'fork source archive did not restore the GITHUB_SHA merge commit')
  assert.call(File.read(File.join(workspace, 'base-context.txt')) == 'merge base context', 'fork source archive omitted merge-commit content')
  assert.call(!File.exist?(File.join(workspace, '.git')), 'fork source artifact must not carry Git credentials or metadata')
  assert.call(!File.exist?(File.join(workspace, 'untracked.txt')), 'fork source artifact included untracked content')

  shared_workspace = File.join(temp, 'shared-pr-worktree')
  File.symlink(repo, shared_workspace)
  source_checks = [prep_steps.find { |step| step['name'] == 'Verify brokered same-repository PR worktree' }, *gates.values.map { |job| job.fetch('steps').find { |step| step['name'] == 'Verify shared PR worktree' } }]
  source_checks.each do |source_check|
    command = source_check.fetch('run')
    check = lambda do |path, expected_sha|
      _output, _status = Open3.capture2e(
        { 'GITHUB_WORKSPACE' => path, 'GITHUB_SHA' => expected_sha, 'EXPECTED_SHA' => expected_sha },
        'bash', '-e', '-o', 'pipefail', '-c', command,
        chdir: path
      )
      _status.success?
    end
    assert.call(check.call(shared_workspace, pr_head_sha), 'brokered PR worktree at the event SHA must pass')
    assert.call(!check.call(shared_workspace, merge_sha), 'brokered PR worktree at another SHA must fail')
    assert.call(!check.call(repo, pr_head_sha), 'ordinary per-job workspace must fail the brokered-worktree check')
  end
end

puts 'CI workflow route contract passed'
