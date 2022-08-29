{{ header }}

{% include 'population.sql' %},

-- for each data source that is used
-- select the metric values
{% for data_source, metrics in metrics_per_dataset.items() -%}
merged_scalars_{{ data_source }} AS (
    SELECT
        DATE({{ metrics[0].data_source.submission_date_column }}) AS submission_date,
        {{ config.population.data_source.client_id_column }} AS client_id,
        p.population_build_id AS build_id,
        ARRAY<
            STRUCT<
                name STRING,
                value FLOAT64
            >
        >[
          {% for metric in metrics -%}
            (
                "{{ metric.name }}",
                CAST({{ metric.select_expression }} AS FLOAT64)
            )
            {{ "," if not loop.last else "" }}
          {% endfor -%}
        ] AS metrics,
    FROM
        {{ metrics[0].data_source.from_expression }}
    RIGHT JOIN
        ( 
            SELECT
                client_id AS population_client_id,
                submission_date AS population_submission_date,
                build_id AS population_build_id
            FROM
              population
        ) AS p
    ON
        {{ metrics[0].data_source.submission_date_column }} = p.population_submission_date AND
        {{ config.population.data_source.client_id_column }} = p.population_client_id
    WHERE
        {% if config.xaxis.value == "submission_date" %}
        DATE({{ metrics[0].data_source.submission_date_column }}) = DATE('{{ submission_date }}')
        {% else %}
        -- when aggregating by build_id, only use the most recent 14 days of data
        DATE({{ metrics[0].data_source.submission_date_column }}) BETWEEN DATE_SUB(DATE('{{ submission_date }}'), INTERVAL 14 DAY) AND DATE('{{ submission_date }}')
        {% endif %}
    GROUP BY
        submission_date,
        build_id,
        client_id
),
{% endfor %}

-- combine the metrics from all the data sources
joined_scalars AS (
  SELECT
    population.submission_date AS submission_date,
    population.client_id AS client_id,
    population.build_id,
    {% for dimension in dimensions -%}
      population.{{ dimension.name }} AS {{ dimension.name }},
    {% endfor %}
    population.branch AS branch,
    ARRAY_CONCAT(
      {% for data_source, metrics in metrics_per_dataset.items() -%}
        COALESCE(merged_scalars_{{ data_source }}.metrics, [])
        {{ "," if not loop.last else "" }}
      {% endfor -%}
    ) AS metrics
  FROM population
  {% for data_source, metrics in metrics_per_dataset.items() -%}
  LEFT JOIN merged_scalars_{{ data_source }}
  USING(submission_date, client_id, build_id)
  {% endfor %}
),

-- unnest the combined metrics so we get
-- the metric values for each client for each date
flattened_scalars AS (
    SELECT * EXCEPT(metrics)
    FROM joined_scalars
    CROSS JOIN UNNEST(metrics)
    {% if not config.population.monitor_entire_population %}
    WHERE branch IN (
        -- If branches are not defined, assume it's a rollout
        -- and fall back to branches labeled as enabled/disabled
        {% if config.population.branches|length > 0  -%}
        {% for branch in config.population.branches -%}
          "{{ branch }}"
          {{ "," if not loop.last else "" }}
        {% endfor -%}
        {% else -%}
        "enabled", "disabled"
        {% endif -%}
    )
    {% endif %}
)
{% if first_run or config.xaxis.value == "submission_date" -%}
SELECT
    submission_date,
    client_id,
    build_id,
    {% for dimension in dimensions -%}
        {{ dimension.name }},
    {% endfor %}
    branch,
    name,
    value
FROM
    flattened_scalars
{% else -%}
-- if data is aggregated by build ID, then aggregate data with previous runs
SELECT
    DATE('{{ submission_date }}') AS submission_date,
    client_id,
    build_id,
    {% for dimension in dimensions -%}
        {{ dimension.name }},
    {% endfor %}
    branch,
    name,
    value
FROM flattened_scalars _current
WHERE 
    PARSE_DATE('%Y%m%d', CAST(build_id AS STRING)) >= DATE_SUB(DATE('{{ submission_date }}'), INTERVAL 14 DAY)
UNION ALL
SELECT
    DATE('{{ submission_date }}') AS submission_date,
    client_id,
    build_id,
    {% for dimension in dimensions -%}
        {{ dimension.name }},
    {% endfor %}
    branch,
    name,
    value
FROM flattened_scalars _prev
WHERE 
    PARSE_DATE('%Y%m%d', CAST(build_id AS STRING)) < DATE_SUB(DATE('{{ submission_date }}'), INTERVAL 14 DAY)
    AND submission_date = DATE_SUB(DATE('{{ submission_date }}'), INTERVAL 1 DAY)
{% endif -%}
