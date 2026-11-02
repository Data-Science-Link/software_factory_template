select *
from {{ ref('agg_spend_by_issue') }}
where spend_usd > {{ var('issue_cap_usd') }}