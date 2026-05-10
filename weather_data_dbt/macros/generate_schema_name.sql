{# ----------------------------------------------------------------------------
   Custom generate_schema_name.

   dbt's default behavior for `+schema: staging` is to produce
   `{profile_dataset}_staging`. We override so that the `dev` target gets a
   `_dev` infix between the profile dataset and the layer schema, while
   `stg` and `prod` use the plain layer schema.

   Resulting BigQuery dataset names (assuming profile dataset = `weather`):

       target.name == 'dev'   →  weather_dev_staging
                                 weather_dev_intermediate
                                 weather_dev_marts

       target.name == 'stg'   →  weather_staging
       target.name == 'prod'      weather_intermediate
                                  weather_marts

       any other target.name  →  {profile_dataset}_{target_name}_{schema}
                                 (defensive default; warns nothing collides)

   Why this lives here rather than in profiles.yml: profile-level dataset
   stays the same `weather` for every env, so secrets / config diffs stay
   minimal across dev / stg / prod. The infix-vs-no-infix decision lives in
   one macro, version-controlled with the project.
---------------------------------------------------------------------------- #}
{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set default_schema = target.schema -%}

    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- elif target.name == 'dev' -%}
        {{ default_schema }}_dev_{{ custom_schema_name | trim }}
    {%- elif target.name in ['stg', 'prod'] -%}
        {{ default_schema }}_{{ custom_schema_name | trim }}
    {%- else -%}
        {{ default_schema }}_{{ target.name }}_{{ custom_schema_name | trim }}
    {%- endif -%}

{%- endmacro %}
