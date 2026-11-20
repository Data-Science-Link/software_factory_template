with normalized as (
    select
        coalesce(nullif(lower(trim(work_type)), ''), 'unknown') as work_type,
        gate_passed,
        actual_cost_usd,
        tokens_in,
        tokens_cached,
        tokens_out,
        actions_minutes
    from {{ ref('fct_agent_runs') }}
),

grouped as (
    select
        work_type,
        count(*) as run_count,
        sum(case when gate_passed then 1 else 0 end) as pass_count,
        round(
            avg(case when gate_passed then 100.0 else 0.0 end),
            6
        ) as pass_rate_pct,
        sum(actual_cost_usd) as total_actual_cost_usd,
        avg(actual_cost_usd) as avg_cost_usd,
        sum(coalesce(tokens_in, 0)) as total_tokens_in,
        sum(coalesce(tokens_cached, 0)) as total_tokens_cached,
        sum(coalesce(tokens_out, 0)) as total_tokens_out,
        sum(coalesce(actions_minutes, 0)) as total_actions_minutes
    from normalized
    group by work_type
),

totals as (
    select coalesce(sum(total_actual_cost_usd), 0) as spend_total
    from grouped
)

select
    g.work_type,
    g.run_count,
    g.pass_count,
    g.pass_rate_pct,
    g.total_actual_cost_usd,
    g.avg_cost_usd,
    round(
        case
            when t.spend_total > 0
                then g.total_actual_cost_usd / t.spend_total * 100
            else 0
        end,
        6
    ) as cost_share_pct,
    g.total_tokens_in,
    g.total_tokens_cached,
    g.total_tokens_out,
    g.total_actions_minutes
from grouped g
cross join totals t
order by g.total_actual_cost_usd desc, g.run_count desc, g.work_type asc