select *
from {{ ref('fct_agent_runs') }}
where actual_cost_usd < 0