select run_id
from {{ ref('fct_agent_runs') }}
where (tokens_in is not null and tokens_in < 0)
   or (tokens_out is not null and tokens_out < 0)
   or (tokens_cached is not null and tokens_cached < 0)
   or (
        tokens_in is not null
        and tokens_cached is not null
        and tokens_cached > tokens_in
    )