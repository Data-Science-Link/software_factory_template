select
    issue,
    count(*) as runs,
    sum(actual_cost_usd) as spend_usd,
    {{ var('issue_cap_usd') }} - sum(actual_cost_usd) as cap_headroom_usd,
    sum(predicted_cost_usd) as predicted_usd,
    sum(actual_cost_usd) - sum(predicted_cost_usd) as variance_usd,
    arg_max(outcome, started_at_utc) as last_outcome,
    max(started_at_utc) as last_run_at_utc
from {{ ref('fct_agent_runs') }}
group by issue