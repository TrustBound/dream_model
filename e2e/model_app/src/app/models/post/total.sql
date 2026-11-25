-- returns: one
-- not null: total
select sum(id)::int as total from posts where user_id = $1
