{{ config(severity='warn') }}
select *
from {{ ref('fct_forecast_vs_actual') }}
where abs(error_pct) > 100
