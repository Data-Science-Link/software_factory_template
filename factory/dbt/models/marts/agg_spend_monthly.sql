with params as (
    select
        coalesce(
            try_cast(nullif('{{ var("as_of_date") }}', '') as date),
            cast(now() at time zone 'UTC' as date)
        ) as as_of_date
),

months as (
    select
        p.as_of_date,
        unnest(generate_series(
            date_trunc('month', p.as_of_date) - interval '2' month,
            date_trunc('month', p.as_of_date),
            interval '1' month
        )) as month_start
    from params p
),

spend as (
    select
        cast(date_trunc('month', f.run_date) as timestamp) as month_start,
        count(*) as runs,
        count(distinct f.issue) as issues,
        sum(f.actual_cost_usd) as spend_usd
    from {{ ref('fct_agent_runs') }} f
    cross join params p
    where f.run_date <= p.as_of_date
      and f.run_date >= date_trunc('month', p.as_of_date) - interval '2' month
    group by cast(date_trunc('month', f.run_date) as timestamp)
),

combined as (
    select
        m.month_start,
        coalesce(s.runs, 0) as runs,
        coalesce(s.issues, 0) as issues,
        coalesce(s.spend_usd, 0) as spend_usd
    from months m
    left join spend s on s.month_start = m.month_start
)

select
    cast(month_start as date) as month_start_utc,
    runs,
    issues,
    spend_usd,
    {{ var('deepinfra_monthly_budget_usd') }} as budget_usd,
    spend_usd / nullif({{ var('deepinfra_monthly_budget_usd') }}, 0) * 100 as budget_used_pct,
    spend_usd > {{ var('deepinfra_monthly_budget_usd') }} as over_budget
from combined
order by month_start_utc
