with efficiency as (
    select coalesce(sum(run_count), 0) as run_count
    from {{ ref('mart_model_efficiency') }}
),

runs as (
    select count(*) as run_count
    from {{ ref('fct_agent_runs') }}
)

select *
from efficiency
cross join runs
where efficiency.run_count <> runs.run_count