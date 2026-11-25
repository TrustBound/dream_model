-- returns: one User
-- unique users_email_key: Email already taken
insert into users (email, nickname) values ($1, $2)
returning id, email, nickname
