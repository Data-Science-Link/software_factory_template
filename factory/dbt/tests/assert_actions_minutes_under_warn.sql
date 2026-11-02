{{ config(severity='warn') }}
select *
from {{ ref('rpt_run_rate') }}
where actions_minutes_used_pct >= {{ var('warn_pct') }}