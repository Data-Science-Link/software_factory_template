{{ config(severity='warn') }}
select *
from {{ ref('rpt_run_rate') }}
where budget_used_pct >= {{ var('warn_pct') }}