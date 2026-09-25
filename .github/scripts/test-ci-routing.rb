require "yaml"

workflow = YAML.load_file(".github/workflows/ci.yml")
jobs = workflow.fetch("jobs")
events = workflow["on"] || workflow[true]
abort "pull_request_target must be enabled without pull_request" unless events.key?("pull_request_target") && !events.key?("pull_request")
abort "workflow token must be read-only" unless workflow.fetch("permissions") == { "contents" => "read" }
router = jobs.fetch("workflow-routing")
abort "workflow routing tests must run on GitHub-hosted Ubuntu" unless router.fetch("runs-on") == "ubuntu-latest"
abort "workflow routing test must run on every event" if router.key?("if")
router_checkout = router.fetch("steps").select { |step| step["uses"] == "actions/checkout@v4.4.0" }
fork_checkout_condition = "github.event_name != 'pull_request_target' || github.event.pull_request.head.repo.full_name != github.repository"
abort "workflow routing must inspect base code for fork PRs" unless router_checkout.any? do |step|
  step["if"] == fork_checkout_condition && !step.fetch("with").key?("ref")
end
abort "trusted PR routing must inspect the merge ref" unless router_checkout.any? do |step|
  step["if"] == "github.event_name == 'pull_request_target' && github.event.pull_request.head.repo.full_name == github.repository" && step.fetch("with").fetch("ref") == "refs/pull/${{ github.event.pull_request.number }}/merge"
end

def condition_matches?(condition, event)
  condition.split(" || ").any? do |any_condition|
    any_condition.split(" && ").all? do |term|
      match = term.match(/\A(github\.event_name|github\.repository|github\.event\.pull_request\.head\.repo\.full_name)\s*(==|!=)\s*('([^']+)'|github\.repository)\z/)
      abort "Unsupported routing condition: #{term}" unless match

      values = {
        "github.event_name" => event.fetch(:name),
        "github.repository" => event.fetch(:repository),
        "github.event.pull_request.head.repo.full_name" => event.fetch(:head_repository, "")
      }
      actual = values.fetch(match[1])
      rhs = match[3]
      expected = rhs.start_with?("'") ? rhs.delete_prefix("'").delete_suffix("'") : values.fetch(rhs)
      match[2] == "==" ? actual == expected : actual != expected
    end
  end
end

cases = [
  { name: "pull_request_target", head_repository: "contributor/crispy-catchup", repository: "moabualruz/crispy-catchup", expected_jobs: [] },
  { name: "pull_request_target", head_repository: "moabualruz/crispy-catchup", repository: "moabualruz/crispy-catchup", expected_jobs: ["test-trusted"] },
  { name: "push", repository: "moabualruz/crispy-catchup", expected_jobs: ["test-trusted"] },
  { name: "workflow_dispatch", repository: "moabualruz/crispy-catchup", expected_jobs: ["test-trusted"] }
]

cases.each do |event|
  active_jobs = jobs.reject { |name, _| name == "workflow-routing" }.select { |_, job| condition_matches?(job.fetch("if"), event) }
  abort "#{event[:name]} routed to #{active_jobs.keys.inspect}" unless active_jobs.keys == event[:expected_jobs]
  active_jobs.each_value do |job|
    abort "trusted routing must use the configured self-hosted runner" unless job.fetch("runs-on") == ["self-hosted", "linux", "x64", "generic"]
  end
end

puts "workflow routing passed: fork PR skipped, same-repository PR and push use trusted runner"
