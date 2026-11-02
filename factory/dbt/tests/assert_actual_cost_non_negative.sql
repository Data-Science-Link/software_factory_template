select *
from {{ ref('stg_agent_runs') }}
where actual_cost_usd < 0
