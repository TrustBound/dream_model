-- returns: one Post
insert into posts (user_id, title, body) values ($1, $2, $3)
returning id, user_id, title, body, published
