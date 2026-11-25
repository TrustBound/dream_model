-- params: limit?
select id from users where $1::int is null or id < $1
