with recursive r(n, e) as (
  select id, email from users
  union all
  select n + 1, e from r where n < 3
)
select e from r
