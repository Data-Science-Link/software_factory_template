select *
from {{ ref('stg_agent_runs') }}
where cost_method = 'usage_x_price_table'
  and abs(actual_cost_usd - (
      (tokens_in - tokens_cached) * price_in_per_mtok
      + tokens_cached * price_cached_per_mtok
      + tokens_out * price_out_per_mtok
  ) / 1e6) > 0.0001
