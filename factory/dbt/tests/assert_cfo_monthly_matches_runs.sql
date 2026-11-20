with params as (
    select
        coalesce(
            try_cast(nullif('{{ var("as_of_date") }}', '') as date),
            cast(now() at time zone 'UTC' as date)
        ) as as_of_date
),

cfo as (
    select coalesce(sum(total_cost_usd), 0) as total_cost_usd
    from {{ ref('mart_monthly_cfo') }}
),

runs as (
    select coalesce(sum(f.actual_cost_usd), 0) as total_cost_usd
    from {{ ref('fct_agent_runs') }} f
    cross join params p
    where f.run_date <= p.as_of_date
      and f.run_date >= date_trunc('month', p.as_of_date) - interval '2' month
)

select *
from cfo
cross join runs
where abs(cfo.total_cost_usd - runs.total_cost_usd) > 0.0001