with per_issue as (
    select
        issue,
        count(*) as runs,
        sum(actual_cost_usd) as spend_usd,
        sum(actual_cost_usd) <= {{ var('issue_target_usd') }} as under_target,
        sum(actual_cost_usd) <= {{ var('issue_cap_usd') }} as under_cap
    from {{ ref('fct_agent_runs') }}
    group by issue
),

summary as (
    select
        cast(null as integer) as issue,
        count(*) as runs,
        sum(spend_usd) as spend_usd,
        bool_and(under_target) as under_target,
        bool_and(under_cap) as under_cap
    from per_issue
),

combined as (
    select
        issue,
        runs,
        spend_usd,
        under_target,
        under_cap
    from per_issue
    union all
    select
        issue,
        runs,
        spend_usd,
        under_target,
        under_cap
    from summary
)

select
    issue,
    runs,
    spend_usd,
    {{ var('issue_target_usd') }} as issue_target_usd,
    {{ var('issue_cap_usd') }} as issue_cap_usd,
    under_target,
    under_cap
from combined
order by issue nulls last
