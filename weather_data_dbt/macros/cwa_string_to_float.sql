{# ----------------------------------------------------------------------------
   cwa_string_to_float

   Convert a STRING-typed measurement column from bronze (which preserves the
   raw CWA value, including sentinels like 'X' / 'T' / '-99' / '990') into a
   FLOAT64 with sentinels translated.

   Sentinel rules (per CWA Open Data spec V1.05, dataset O-A0003-001):

       Default (all measurements except wind direction and precipitation):
           'X', -99, -999  →  NULL
           ('X' = instrument malfunction; -99/-999 = missing/abnormal)

       Wind direction (caller passes extra_null_numeric=[990]):
           'X', -99, -999, 990  →  NULL
           (990 = "calm wind, undefined direction")

       Precipitation (caller passes zero_strings=['T'], zero_numerics=[-98]):
           'X', -99, -999  →  NULL
           'T'             →  0   (trace amount, too small to measure)
           -98             →  0   (no rain in past 6 hours)
           Precipitation in legacy backfill also carries -990 as an
           undocumented sentinel — pass extra_null_numeric=[-990] to drop it.

   Why numeric comparison via SAFE_CAST?
       Legacy and new data disagree on string format: legacy stores
       '-99.0' (decimal form), new crawler stores '-99' (integer form).
       Comparing the SAFE_CAST result against a numeric list (-99, -999, ...)
       matches both '-99' and '-99.0' transparently. SAFE_CAST returns NULL
       on parse failure, so 'X' is special-cased before the cast.

   Args:
       col                  column name (must be STRING in source table)
       extra_null_numeric   numeric sentinels (in addition to -99 / -999)
                            that should map to NULL
       zero_strings         non-numeric string sentinels mapping to 0 (e.g. 'T')
       zero_numerics        numeric sentinels mapping to 0 (e.g. -98)
---------------------------------------------------------------------------- #}
{% macro cwa_string_to_float(col, extra_null_numeric=[], zero_strings=[], zero_numerics=[]) %}
    (
        case
        {%- if zero_strings %}
            when {{ col }} in ({% for v in zero_strings %}'{{ v }}'{% if not loop.last %}, {% endif %}{% endfor %}) then 0
        {%- endif %}
        {%- if zero_numerics %}
            when safe_cast({{ col }} as float64) in ({{ zero_numerics | join(', ') }}) then 0
        {%- endif %}
            when {{ col }} = 'X' then null
            when safe_cast({{ col }} as float64) in (-99, -999{% for v in extra_null_numeric %}, {{ v }}{% endfor %}) then null
            else safe_cast({{ col }} as float64)
        end
    )
{% endmacro %}
