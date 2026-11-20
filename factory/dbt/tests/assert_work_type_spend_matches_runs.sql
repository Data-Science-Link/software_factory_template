with spend as (
    select
        coalesce(sum(run_count), 0) as run_count,
        coalesce(sum(total_actual_cost_usd), 0) as total_actual_cost_usd
    from {{ ref('mart_spend_by_work_type') }}
),

runs as (
    select
        count(*) as run_count,
        coalesce(sum(actual_cost_usd), 0) as total_actual_cost_usd
    from {{ ref('fct_agent_runs') }}
)

select *
from spend
cross join runs
where spend.run_count <> runs.run_count
   or abs(spend.total_actual_cost_usd - runs.total_actual_cost_usd) > 1e-6