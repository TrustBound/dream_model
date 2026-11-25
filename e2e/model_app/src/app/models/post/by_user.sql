-- returns: many Post
select id, user_id, title, body, published from posts
where user_id = $1 order by id
