select *
from {{ ref('agg_spend_weekly') }}
where budget_used_pct <> round(
    spend_usd / nullif(budget_usd, 0) * 100,
    6
)
