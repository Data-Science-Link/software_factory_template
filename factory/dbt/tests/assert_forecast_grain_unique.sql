select
    grain,
    grain_key,
    count(*) as row_count
from {{ ref('fct_forecast_vs_actual') }}
group by grain, grain_key
having count(*) > 1