select
    run_date as spend_date,
    count(*) as runs,
    sum(actual_cost_usd) as spend_usd,
    sum(tokens_in) as tokens_in,
    sum(tokens_cached) as tokens_cached,
    sum(tokens_out) as tokens_out,
    sum(actions_minutes) as actions_minutes
from {{ ref('fct_agent_runs') }}
group by run_date