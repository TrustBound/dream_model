-- returns: many User
-- params: pattern, nickname?
select id, email, nickname from users
where email like $1 and ($2::text is null or nickname = $2)
order by id
