require "yaml"

workflow = YAML.load_file(".github/workflows/ci.yml")
jobs = workflow.fetch("jobs")
events = workflow["on"] || workflow[true]
abort "CI must use pull_request, not pull_request_target" unless events.key?("pull_request") && !events.key?("pull_request_target")
abort "workflow token must be read-only" unless workflow.fetch("permissions") == { "contents" => "read" }

release_workflow = YAML.load_file(".github/workflows/release.yml")
release_events = release_workflow["on"] || release_workflow[true]
abort "release must remain manually dispatched" unless release_events.keys == ["workflow_dispatch"]
abort "release token must be read-only" unless release_workflow.fetch("permissions") == { "contents" => "read" }

trusted_runner = "${{ (github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository && github.event.pull_request.user.login == github.repository_owner && github.actor == github.repository_owner && fromJSON(format('[\"self-hosted\", \"linux\", \"x64\", \"generic\", \"pr-{0}-{1}-run-{2}-attempt-{3}\"]', github.repository_id, github.event.pull_request.number, github.run_id, github.run_attempt))) || ((github.event_name == 'push' && github.ref == 'refs/heads/main' && github.actor == github.repository_owner || github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main' && github.actor == github.repository_owner) && fromJSON('[\"self-hosted\", \"linux\", \"x64\", \"generic\"]')) || 'ubuntu-latest' }}"
checkout_condition = "github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name != github.repository || github.event.pull_request.user.login != github.repository_owner || github.actor != github.repository_owner"
prepare = jobs.fetch("prepare")
gate = jobs.fetch("gate")
abort "prepare and gate must use run-scoped trusted routing" unless prepare.fetch("runs-on") == trusted_runner && gate.fetch("runs-on") == trusted_runner
abort "gate jobs must depend on serial preparation" unless gate.fetch("needs") == "prepare"
abort "gate matrix must include every independent Rust check" unless gate.dig("strategy", "matrix", "gate") == %w[fmt clippy test doc package]
prepare_steps = prepare.fetch("steps")
gate_steps = gate.fetch("steps")
abort "workflow must check out source only once" unless prepare_steps.count { |step| step["uses"] == "actions/checkout@v4.4.0" } == 1
checkout = prepare_steps.find { |step| step["uses"] == "actions/checkout@v4.4.0" }
abort "trusted PR source must use the prepared host worktree" unless checkout.fetch("if") == checkout_condition
abort "routing proof must run during preparation" unless prepare_steps.any? { |step| step["run"] == "ruby .github/scripts/test-ci-routing.rb" }
source_upload = prepare_steps.find { |step| step["uses"] == "actions/upload-artifact@v4" }
abort "hosted fallback must upload one prepared source archive" unless source_upload && source_upload.fetch("if") == checkout_condition
abort "gate jobs must reuse source without checkout" if gate_steps.any? { |step| step["uses"] == "actions/checkout@v4.4.0" }
source_download = gate_steps.find { |step| step["uses"] == "actions/download-artifact@v4" }
abort "hosted fallback must download the prepared source" unless source_download && source_download.fetch("if") == checkout_condition
abort "dependencies must be fetched once before parallel gates" unless prepare_steps.any? { |step| step["run"] == "cargo fetch" }
abort "Rust dependency cache must be restored for each gate" unless gate_steps.any? { |step| step["uses"] == "actions/cache/restore@v4" }

release_job = release_workflow.fetch("jobs").fetch("release-check")
release_runner = "${{ github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main' && github.actor == github.repository_owner && fromJSON('[\"self-hosted\", \"linux\", \"x64\", \"generic\"]') || 'ubuntu-latest' }}"
abort "release self-hosted runner must require owner dispatch from main" unless release_job.fetch("runs-on") == release_runner

def expected_runner(event)
  trusted_pr = event[:name] == "pull_request" &&
    event[:head_repository] == "moabualruz/crispy-catchup" &&
    event[:author] == "moabualruz" && event[:actor] == "moabualruz"
  if trusted_pr
    "self-hosted:pr-#{event[:repository_id]}-#{event[:pr]}-run-#{event[:run_id]}-attempt-#{event[:attempt]}"
  elsif %w[push workflow_dispatch].include?(event[:name]) &&
      event[:ref] == "refs/heads/main" && event[:actor] == "moabualruz"
    ["self-hosted", "linux", "x64", "generic"]
  else
    "ubuntu-latest"
  end
end

def checkout_required?(event)
  !(event[:name] == "pull_request" &&
    event[:head_repository] == "moabualruz/crispy-catchup" &&
    event[:author] == "moabualruz" && event[:actor] == "moabualruz")
end

cases = [
  { name: "pull_request", source: "fork", head_repository: "contributor/crispy-catchup", author: "moabualruz", actor: "moabualruz", ref: "refs/pull/2/merge", repository_id: 11, pr: 2, run_id: 50, attempt: 1 },
  { name: "pull_request", source: "same-repo-owner", head_repository: "moabualruz/crispy-catchup", author: "moabualruz", actor: "moabualruz", ref: "refs/pull/2/merge", repository_id: 11, pr: 2, run_id: 50, attempt: 1 },
  { name: "pull_request", source: "same-repo-non-owner", head_repository: "moabualruz/crispy-catchup", author: "contributor", actor: "moabualruz", ref: "refs/pull/3/merge", repository_id: 11, pr: 3, run_id: 51, attempt: 1 },
  { name: "pull_request", source: "owner-PR-other-actor", head_repository: "moabualruz/crispy-catchup", author: "moabualruz", actor: "contributor", ref: "refs/pull/2/merge", repository_id: 11, pr: 2, run_id: 52, attempt: 1 },
  { name: "push", actor: "moabualruz", ref: "refs/heads/main", repository_id: 11, pr: 0, run_id: 53, attempt: 1 },
  { name: "push", actor: "contributor", ref: "refs/heads/main", repository_id: 11, pr: 0, run_id: 54, attempt: 1 },
  { name: "workflow_dispatch", actor: "moabualruz", ref: "refs/heads/main", repository_id: 11, pr: 0, run_id: 55, attempt: 1 },
  { name: "workflow_dispatch", actor: "moabualruz", ref: "refs/heads/feature", repository_id: 11, pr: 0, run_id: 56, attempt: 1 },
  { name: "workflow_dispatch", actor: "contributor", ref: "refs/heads/main", repository_id: 11, pr: 0, run_id: 57, attempt: 1 }
]

cases.each do |event|
  actual = expected_runner(event)
  abort "#{event[:source] || event[:name]} was not eligible for the full gate" unless %w[ubuntu-latest self-hosted:pr-11-2-run-50-attempt-1].include?(actual) || actual.is_a?(Array)
  if event[:name] == "pull_request"
    abort "fork PR was not sent to hosted runners" if event[:source] == "fork" && actual != "ubuntu-latest"
    abort "owner PR did not get its run-scoped runner" if event[:source] == "same-repo-owner" && actual != "self-hosted:pr-11-2-run-50-attempt-1"
    abort "non-owner PR reached self-hosted runners" if %w[same-repo-non-owner owner-PR-other-actor].include?(event[:source]) && actual != "ubuntu-latest"
    abort "trusted PR must reuse prepared source" if event[:source] == "same-repo-owner" && checkout_required?(event)
    abort "untrusted PR must check out its source" if event[:source] != "same-repo-owner" && !checkout_required?(event)
  end
end

puts "workflow routing passed: forks run all hosted gates; trusted PR gates reuse one run-scoped worktree"
