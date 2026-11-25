-- returns: one User
-- not found: User not found
select id, email, nickname from users where id = $1
