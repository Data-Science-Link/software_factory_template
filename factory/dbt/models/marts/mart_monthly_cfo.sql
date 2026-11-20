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

run_stats as (
    select
        cast(date_trunc('month', f.run_date) as timestamp) as month_start,
        count(*) as run_count,
        count(distinct f.issue) as distinct_issues,
        sum(f.actual_cost_usd) as total_cost_usd,
        sum(case when f.gate_passed then 1 else 0 end) as passed_count
    from {{ ref('fct_agent_runs') }} f
    cross join params p
    where f.run_date <= p.as_of_date
      and f.run_date >= date_trunc('month', p.as_of_date) - interval '2' month
    group by cast(date_trunc('month', f.run_date) as timestamp)
),

combined as (
    select
        m.month_start,
        coalesce(r.run_count, 0) as run_count,
        coalesce(r.distinct_issues, 0) as distinct_issues,
        coalesce(r.total_cost_usd, 0) as total_cost_usd,
        coalesce(r.passed_count, 0) as passed_count
    from months m
    left join run_stats r on r.month_start = m.month_start
)

select
    cast(month_start as date) as month_start,
    run_count,
    distinct_issues,
    total_cost_usd,
    {{ var('deepinfra_monthly_budget_usd') }} as monthly_budget_usd,
    round(
        total_cost_usd / nullif({{ var('deepinfra_monthly_budget_usd') }}, 0) * 100,
        6
    ) as budget_used_pct,
    case
        when run_count > 0
            then round(passed_count::double / run_count * 100, 6)
        else null
    end as pass_rate_pct,
    case
        when distinct_issues > 0
            then total_cost_usd / distinct_issues
        else null
    end as avg_cost_per_issue_usd
from combined
order by month_start