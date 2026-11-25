-- returns: many
select id, happened_at from samples
where isfinite(happened_at)
