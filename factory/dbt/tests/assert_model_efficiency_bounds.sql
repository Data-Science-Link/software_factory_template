select
    efficiency_grain_key,
    run_count,
    pass_rate_pct,
    total_cost_usd,
    avg_cost_usd
from {{ ref('mart_model_efficiency') }}
where run_count <= 0
   or (pass_rate_pct is not null and (pass_rate_pct < 0 or pass_rate_pct > 100))
   or (total_cost_usd is not null and total_cost_usd < 0)
   or (avg_cost_usd is not null and avg_cost_usd < 0)
   or (
        cost_per_passed_run_usd is not null
        and cost_per_passed_run_usd < 0
    )