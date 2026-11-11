with params as (
    select
        coalesce(
            try_cast(nullif('{{ var("as_of_date") }}', '') as date),
            cast(now() at time zone 'UTC' as date)
        ) as as_of_date
),

weeks as (
    select
        p.as_of_date,
        unnest(generate_series(
            date_trunc('week', date_trunc('month', p.as_of_date)),
            cast(p.as_of_date as timestamp),
            interval '1' week
        )) as week_start
    from params p
),

spend as (
    select
        cast(date_trunc('week', f.run_date) as timestamp) as week_start,
        count(*) as runs,
        count(distinct f.issue) as issues,
        sum(f.actual_cost_usd) as spend_usd
    from {{ ref('fct_agent_runs') }} f
    cross join params p
    where f.run_date between date_trunc('month', p.as_of_date) and p.as_of_date
    group by cast(date_trunc('week', f.run_date) as timestamp)
),

combined as (
    select
        w.week_start,
        coalesce(s.runs, 0) as runs,
        coalesce(s.issues, 0) as issues,
        coalesce(s.spend_usd, 0) as spend_usd
    from weeks w
    left join spend s on s.week_start = w.week_start
)

select
    cast(week_start as date) as week_start_utc,
    cast(date_trunc('week', week_start) + interval '6' day as date) as week_end_utc,
    cast(extract(isoyear from week_start) as integer) as iso_year,
    cast(extract(week from week_start) as integer) as iso_week,
    runs,
    issues,
    spend_usd,
    {{ var('weekly_budget_usd') }} as budget_usd,
    spend_usd / nullif({{ var('weekly_budget_usd') }}, 0) * 100 as budget_used_pct,
    spend_usd > {{ var('weekly_budget_usd') }} as over_budget
from combined
order by week_start_utc
