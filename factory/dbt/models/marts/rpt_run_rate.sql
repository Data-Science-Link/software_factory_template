with params as (
    select
        coalesce(
            try_cast(nullif('{{ var("as_of_date") }}', '') as date),
            cast(now() at time zone 'UTC' as date)
        ) as as_of_date
),

rates as (
    select
        p.as_of_date,
        date_trunc('month', p.as_of_date) as month_start,
        day(p.as_of_date) as days_elapsed,
        day(last_day(p.as_of_date)) as days_in_month,
        coalesce(sum(f.actual_cost_usd) filter (
            where f.run_date >= date_trunc('month', p.as_of_date)
              and f.run_date <= p.as_of_date
        ), 0) as mtd_variable_usd,
        coalesce(sum(f.actual_cost_usd) filter (
            where f.run_date > p.as_of_date - interval '7' day
              and f.run_date <= p.as_of_date
        ), 0) / 7.0 as trailing_7d_usd_per_day,
        coalesce(sum(f.actual_cost_usd) filter (
            where f.run_date > p.as_of_date - interval '30' day
              and f.run_date <= p.as_of_date
        ), 0) / 30.0 as trailing_30d_usd_per_day,
        coalesce(sum(f.actions_minutes) filter (
            where f.run_date >= date_trunc('month', p.as_of_date)
              and f.run_date <= p.as_of_date
        ), 0) as actions_minutes_mtd
    from params p
    left join {{ ref('fct_agent_runs') }} f on true
    group by
        p.as_of_date,
        date_trunc('month', p.as_of_date),
        day(p.as_of_date),
        day(last_day(p.as_of_date))
)

select
    as_of_date,
    month_start,
    days_elapsed,
    days_in_month,
    mtd_variable_usd,
    trailing_7d_usd_per_day,
    trailing_30d_usd_per_day,
    mtd_variable_usd / days_elapsed * days_in_month as projected_month_end_variable_usd,
    {{ var('fixed_costs_monthly_usd') }} as fixed_costs_month_usd,
    mtd_variable_usd + {{ var('fixed_costs_monthly_usd') }} as total_mtd_usd,
    projected_month_end_variable_usd + {{ var('fixed_costs_monthly_usd') }} as projected_month_end_total_usd,
    {{ var('deepinfra_monthly_budget_usd') }} as deepinfra_budget_usd,
    mtd_variable_usd / {{ var('deepinfra_monthly_budget_usd') }} * 100 as budget_used_pct,
    actions_minutes_mtd,
    {{ var('actions_minutes_month') }} as actions_minutes_quota,
    actions_minutes_mtd / {{ var('actions_minutes_month') }} * 100 as actions_minutes_used_pct
from rates