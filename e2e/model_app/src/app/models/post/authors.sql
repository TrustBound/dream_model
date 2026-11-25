-- returns: many app/models/user.User
select distinct users.id, users.email, users.nickname
from users join posts on posts.user_id = users.id
where posts.published = $1
order by users.id
