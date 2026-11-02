with measured as (
    select *
    from {{ ref('fct_agent_runs') }}
    where cost_method <> 'not_measured'
),

by_issue as (
    select
        'issue' as grain,
        cast(issue as varchar) as grain_key,
        count(*) as runs,
        sum(predicted_cost_usd) as predicted_usd,
        sum(actual_cost_usd) as actual_usd,
        median(tokens_in) as median_tokens_in,
        median(tokens_cached) as median_tokens_cached,
        median(tokens_out) as median_tokens_out
    from measured
    group by issue
),

by_complexity as (
    select
        'complexity' as grain,
        complexity as grain_key,
        count(*) as runs,
        sum(predicted_cost_usd) as predicted_usd,
        sum(actual_cost_usd) as actual_usd,
        median(tokens_in) as median_tokens_in,
        median(tokens_cached) as median_tokens_cached,
        median(tokens_out) as median_tokens_out
    from measured
    group by complexity
),

combined as (
    select * from by_issue
    union all
    select * from by_complexity
)

select
    grain,
    grain_key,
    runs,
    predicted_usd,
    actual_usd,
    median_tokens_in,
    median_tokens_cached,
    median_tokens_out,
    case
        when predicted_usd > 0
            then (actual_usd - predicted_usd) / predicted_usd * 100
        else null
    end as error_pct
from combined
