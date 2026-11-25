-- returns: maybe User
select id, email, nickname from users where email = $1
