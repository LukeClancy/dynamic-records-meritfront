# Dynamic Records Meritfront

Dyanmic Records Meritfront helps extend active record functionality to make it more dynamic. These methods have the goal of allowing one to
1. communicate with the frontend quicker and more effectively through Global HashIds
2. communicate with the backend more effectively with raw sql queries. This becomes especially relevant when you hit the limits of Active Record Relations and the usual way of querying in rails. For instance, if you have a page-long dynamic sql query.

Note that postgres is a requirement for this gem. I dont tend to get much feedback, so any given would be appreciated.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'dynamic-records-meritfront'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install dynamic-records-meritfront

## Usage

### Apply to your ApplicationRecord class as such

```ruby
class ApplicationRecord < ActiveRecord::Base
	self.abstract_class = true
	include DynamicRecordsMeritfront
	DYNAMIC_SQL_RAW = false #<--- not required, but suggested to be turned off. Can be switched on for a per-request basis. Make sure this line is after include statement.
end
```

### SQL methods

These are methods written for easier sql usage.

#### self.dynamic_sql(name, sql, opts = { })
A better and safer way to write sql. Can return either a Hash, ActiveRecord::Response object, or an instantiated model.
with options: 
- instantiate_class: returns User, Post, etc objects instead of straight sql output.
    I prefer doing the alterantive
        ```User.dynamic_sql(...)```
        which is also supported
- prepare: sets whether the db will preprocess the strategy for lookup (defaults true) (have not verified the prepared-ness)
- name_modifiers: allows one to change the preprocess associated name, useful in cases of dynamic sql.
- multi_query: allows more than one query (you can seperate an insert and an update with ';' I dont know how else to say it.)
    this disables other options including arguments (except name_modifiers). Not sure how it effects prepared statements.
- async: Gets passed to ActiveRecord::Base.connection.exec_query as a parameter. See that methods documentation for more. I was looking through the source code, and I think it only effects how it logs to the logfile?
- raw: whether to return a ActiveRecord::Response object or a hash when called on an abstract class (ApplicationRecord vs User)
- other options: considered sql arguments
	
<details>
<summary>example usage</summary>
Delete Friend Requests between two users after they have become friends.

```ruby
    ApplicationRecord.dynamic_sql("remove_friend_requests_before_creating_friend", %Q{
        DELETE FROM friend_requests
        WHERE (requestie_id = :uid and requester_id = :other_user_id) OR
            (requester_id = :uid and requestie_id = :other_user_id)
    }, uid: Current.user.id, other_user_id: other_user.id)
```
</details>

<details>
<summary>dynamic sql example usage</summary>
Get all users who have made a friend request to a particular user with an optional limit.
This is an example of why this method is good for dynamic prepared statements.

```ruby
    return User.dynamic_sql('get_friend_requests', %Q{
        SELECT * FROM (
            SELECT other_user.id, ..., friend_requests.created_at
            FROM users
                INNER JOIN friend_requests ON users.id = friend_requests.requestie_id
                INNER JOIN users other_user ON friend_requests.requester_id = other_user.id
            WHERE users.id = :uid
        ) AS all_friend_requests
        ORDER BY all_friend_requests.created_at DESC
        #{"LIMIT :limit" if limit > 0}
    }, uid: u, limit: limit, name_modifiers: [
        limit > 0 ? 'limited' : nil
    ])
```
</details>
	
<details>
<summary>access non-standard column for table with a ActiveRecord model</summary>

```ruby
    #get a normal test vote
    test =  Vote.dynamic_sql('test', %Q{
        SELECT id FROM votes LIMIT 1
    }).first
    v.inspect 	#   "#<Vote id: 696969>"

    #get a cool test vote. Note that is_this_vote_cool is not on the vote table.
    test =  Vote.dynamic_sql('test', %Q{
        SELECT id, 'yes' AS is_this_vote_cool FROM votes LIMIT 1
    }).first
   test.inspect #   #<Vote id: 696969, is_this_vote_cool: "yes"> #getting attributes added dynamically to the models, and also showing up on inspects, was... more difficult than i anticipated.
```
</details>

<details>
<summary>example usage with selecting records that match list of ids</summary>
Get users who match a list of ids. Uses a postgresql Array, see the potential issues section

```ruby
	id_list = [1,2,3]
	return User.dynamic_sql('get_usrs', %Q{
		SELECT * FROM users WHERE id = ANY (:id_list)
	}, id_list: id_list)
```
</details>
	
<details>
<summary>example usage a custom upsert</summary>
Do an upsert

```ruby
	rows = uzrs.map{|u| [
		u.id,		#user_id
		self.id,	#conversation_id
		from,		#invited_by
		t,		#created_at
		t,		#updated_at
	]}
	ApplicationRecord.dynamic_sql("upsert_conversation_invites_2", %Q{
		INSERT INTO conversation_participants (user_id, conversation_id, invited_by, created_at, updated_at)
		VALUES :rows
		ON CONFLICT (conversation_id,user_id)
		DO UPDATE SET updated_at = :time
	}, rows: rows, time: t)
```
This will output sql similar to below. Note this can be done for multiple conversation_participants. Also note that it only sent one time variable as an argument as dynamic_sql detected that we were sending duplicate information.
```sql
	INSERT INTO conversation_participants (user_id, conversation_id, invited_by, created_at, updated_at)
	VALUES ($1,$2,$3,$4,$4)
	ON CONFLICT (conversation_id,user_id)
	DO UPDATE SET updated_at = $4
	-- [["rows_1", 15], ["rows_2", 67], ["rows_3", 6], ["rows_4", "2022-10-13 20:49:27.441372"]]
```
</details>
	

#### self.dynamic_preload(records, associations)
Preloads from a list of records, and not from a ActiveRecord_Relation. This will be useful when using the above dynamic_sql method (as it returns a list of records, and not a record relation). This is basically the same as a normal relation preload but it works on a list. 

<details>
<summary>example usage</summary>
Preload :votes on some comments. :votes is an active record has_many relation.

```ruby
    comments = Comment.dynamic_sql('get_comments', %Q{
        SELECT * FROM comments LIMIT 4
    })
    comments.class.to_s # 'Array' note: not a relation.
    ApplicationRecord.headache_preload(comments, [:votes])
    puts comments[0].votes #this line should be preloaded and hence not call the database

    #note that this above is basically the same as doing the below assuming there is a comments relation on the user model.
    user.comments.preload(:votes)
```
</details>

#### has_run_migration?(nm)

put in a string name of the migration's class and it will say if it has allready run the migration.
good during enum migrations as the code to migrate wont run if enumerate is there 
as it is not yet enumerated (causing an error when it loads the class that will have the
enumeration in it). This can lead it to being impossible to commit clean code.

<details><summary>example usage</summary>
only load relationa if it exists in the database

```ruby
if ApplicationRecord.has_run_migration?('UserImageRelationsTwo')
    class UserImageRelation < ApplicationRecord
        belongs_to :imageable, polymorphic: true
        belongs_to :image
    end
else
    class UserImageRelation; end
end

```
</details>

#### has_association?(*args)

accepts a list, checks if the model contains those associations

<details><summary>example usage</summary>
Check if object is a votable class

```ruby
obj = Comment.first
obj.has_association?(:votes) #true
obj = User.first
obj.has_association?(:votes) #false
```
</details>

#### self.dynamic_instaload_sql(name, insta_array, opts = { })
*instaloads* a bunch of diffrent models at the same time by casting them to json before returning them. Kinda cool. Seems to be more efficient to preloading when i tested it.
- name is passed to dynamic_sql and is the name of the sql request
- opts are passed to dynamic_sql (except for the raw option which is set to true. Raw output is not allowed on this request)
- requires a list of instaload method output which provides information for how to treat each sql block.
	
<details>
<summary>example usage</summary>
#get list of users, those users friends, and who those users follow, all in one request.

```ruby
   # the ruby entered
   output = ApplicationRecord.dynamic_instaload_sql('test', [
      User.instaload('SELECT id FROM users WHERE users.id = ANY (:user_ids) AND users.created_at > :time', table_name: 'limited_users', relied_on: true),
      User.instaload(%Q{
         SELECT friends.smaller_user_id AS id, friends.bigger_user_id AS friended_to
         FROM friends INNER JOIN limited_users ON limited_users.id = bigger_user_id
         UNION
         SELECT friends.bigger_user_id AS id, friends.smaller_user_id AS friended_to
	 FROM friends INNER JOIN limited_users ON limited_users.id = smaller_user_id
      }, table_name: 'users_friends'),
      ApplicationRecord.instaload(%Q{
         SELECT follows.followable_id, follows.follower_id
         FROM follows
         INNER JOIN limited_users ON follows.follower_id = limited_users.id
      }, table_name: "users_follows")
   ], user_ids: uids, time: t)
```
the sql:
```sql
   WITH limited_users AS (
      SELECT id FROM users WHERE users.id = ANY ($1) AND users.created_at > $2
   )
   SELECT row_to_json(limited_users.*) AS row, 'User' AS _klass, 'limited_users' AS _table_name FROM limited_users
   UNION ALL 
   SELECT row_to_json(users_friends.*) AS row, 'User' AS _klass, 'users_friends' AS _table_name FROM (
         SELECT friends.smaller_user_id AS id, friends.bigger_user_id AS friended_to
         FROM friends INNER JOIN limited_users ON limited_users.id = bigger_user_id
         UNION
         SELECT friends.bigger_user_id AS id, friends.smaller_user_id AS friended_to
         FROM friends INNER JOIN limited_users ON limited_users.id = smaller_user_id
      ) AS users_friends
   UNION ALL 
   SELECT row_to_json(users_follows.*) AS row, 'ApplicationRecord' AS _klass, 'users_follows' AS _table_name FROM (
         SELECT follows.followable_id, follows.follower_id
         FROM follows
         INNER JOIN limited_users ON follows.follower_id = limited_users.id
      ) AS users_follows
```
	
the output:
```ruby
{"limited_users"=>
  [#<User id: 3>,
   #<User id: 14>,
   #<User id: 9>,
   ...],
 "users_friends"=>
  [#<User id: 9, friended_to: 14>,
   #<User id: 21, friended_to: 14>,
   #<User id: 14, friended_to: 9>,
   ...],
 "users_follows"=>
  [{"followable_id"=>931, "follower_id"=>23},
   {"followable_id"=>932, "follower_id"=>23},
   {"followable_id"=>935, "follower_id"=>19},
   ...]}


```
</details>
	
#### self.instaload(sql, table_name: nil, relied_on: false)
Used in dynamic_instaload_sql, and formats information for that method. 

#### self.dynamic_attach(instaload_sql_output, base_name, attach_name, base_on: nil, attach_on: nil, one_to_one: false)
taking the output of the dynamic_instaload_sql, this method attaches the models together so they are attached.
- base_name: the name of the table we will be attaching to
- attach_name: the name of the table that will be attached
- base_on: put a proc here to override the matching key for the base table. Default is, for a user and post type, {|user| user.id}
- attach_on: put a proc here to override the matching key for the attach table. Default is, for a user and post type, {|post| post.user_id}
- one_to_one: switches between a one-to-one relationship or not

<details> 
<summary> attach information for each limited_user in the dynamic_instaload_sql example </summary>
	
```ruby
	
ApplicationRecord.dynamic_attach(out, 'limited_users', 'users_friends', attach_on: Proc.new {|users_friend|
	users_friend.friended_to
})
ApplicationRecord.dynamic_attach(out, 'limited_users', 'users_follows', attach_on: Proc.new {|follow|
	follow['follower_id']
})
pp out['limited_users']

```

printed output: 
```ruby
#<User id: 3, users_friends: [#<User id: 5, friended_to: 3>, #<User id: 6, friended_to: 3>, #<User id: 21, friended_to: 3>], users_follows: [{"followable_id"=>935, "follower_id"=>3}, {"followable_id"=>938, "follower_id"=>3}, ...]>,
 #<User id: 14, users_friends: [#<User id: 9, friended_to: 14>, #<User id: 21, friended_to: 14>, ...], users_follows: [{"followable_id"=>936, "follower_id"=>14}, {"followable_id"=>937, "follower_id"=>14}, {"followable_id"=>938, "follower_id"=>14}, ...]>,
 #<User id: 9, users_friends: [#<User id: 14, friended_to: 9>, #<User id: 22, friended_to: 9>, ...], users_follows: [{"followable_id"=>938, "follower_id"=>9}, {"followable_id"=>937, "follower_id"=>9}, ...]>,
 #<User id: 19, users_friends: [#<User id: 1, friended_to: 19>, #<User id: 18, friended_to: 19>, ...], users_follows: [{"followable_id"=>935, "follower_id"=>19}, {"followable_id"=>936, "follower_id"=>19}, {"followable_id"=>938, "follower_id"=>19}, ...]>,
```

</details>
	
### Hashed Global IDS

hashed global ids look like this: "gid://meritfront/User/K9YI4K". They also have an optional tag so it can also look like "gid://meritfront/User/K9YI4K@user_image". They are based on global ids.

I have been using hgids (Hashed Global IDs) for a while now and they have some unique benefits in front-end back-end communication. This is as they:
1. hash the id which is good practice
2. provide a way to have tags, this is good when updating different UI elements dynamically from the backend. For instance updating the @user_image without affecting the @user_name
3. Carry the class with them, this can allow for more abstract and efficient code, and prevents id collisions between diffrent classes.

#### methods from the hashid-rails gem

See the hashid-rails gem for more (https://github.com/jcypret/hashid-rails). Also note that I aliased .hashid to .hid and .find_by_hashid to .hfind

#### methods from this gem

1. hgid(tag: nil) - get the hgid with optional tag. Aliased to ghid
2. hgid_as_selector(str, attribute: 'id') - get a css selector for the hgid, good for updating the front-end (especially over cable-ready and morphdom operations)
3. self.locate_hgid(hgid_string, with_associations: nil, returns_nil: false) - locates the database record from a hgid. Here are some examples of usage:
    - ApplicationRecord.locate_hgid(hgid) - <b>DANGEROUS</b> will return any object referenced by the hgid.
    - User.locate_hgid(hgid) - locates the User record but only if the hgid references a user class. Fires an error if not.
    - ApplicationRecord.locate_hgid(hgid, with_associations: [:votes]) - locates the record but only if the  record's class has a :votes active record association. So for instance, you can accept only votable objects for upvote functionality. Fires an error if the hgid does not match.
    - User.locate_hgid(hgid, returns_nil: true) - locates the hgid but only if it is the user class. Returns nil if not.
4. get_hgid_tag(hgid) - returns the tag attached to the hgid
5. self.blind_hgid(id, tag: nil, encode: true) - creates a hgid without bringing the object down from the database. Useful with hashid-rails encode_id and decode_id methods.

## Potential Issues

- This gem was made with a postgresql database. This could cause a lot of issues with the sql-related methods if you do not. I dont have the bandwidth to help switch it elsewhere, but if you want to take charge of that, I would be more than happy to assist by answering questions an pointing out any areas that need transitioning.
- If you return a password column (for example) as pwd, this gem will accept that. That would mean that the password could me accessed as model.pwd. This is cool - until all passwords are getting logged in production servers. So be wary of accessing, storing, and logging of sensative information. Active Record has in built solutions for this type of data, as long as you dont change the column name. This gem is a sharp knife, its very versitile, but its also, you know, sharp.
	
## Changelog
	
1.1.10
- Added functionality in headache_sql where for sql arguments that are equal, we only use one sql argument instead of repeating arguments
- Added functionality in headache_sql for 'multi row expressions' which are inputtable as an Array of Arrays. See the upsert example in the headache_sql documentation above for more.
- Added a warning in the README for non-postgresql databases. Contact me if you hit issues and we can work it out.

1.1.11
- Added encode option for blind_hgid to allow creation of just a general gid

2.0.2
- major changes to the gem
- many methods changed names from headache... to dynamic... but I threw in some aliases so both work
- when using dynamic_sql (headache_sql), if you select a column name that doesn't officialy exist on that model, it gets put in the new attr_accessor called dynamic. This allows for more dynamic usage of AR and avoids conflicts with its interal workings (which assume every attribute corresponds to an actual table-column).
- dynamic_sql can be configured to return a hash rather than the current default which is a ActiveRecord::Response object, this can be configured with the DYNAMIC_SQL_RAW variable on your abstract class (usually ApplicationRecord) or per-request with the new :raw option on dynamic_sql. The hash is way better but I made it optional for backwards compat.
- dynamic_instaload_sql is now a thing. It seems to be more efficient than preloading. See more above.
- the output of dynamic_instaload_sql can be made more useful with dynamic_attach. See more above.
- postgres is now a pretty hard requirement as I use its database features liberally and I am somewhat certain that other databases wont work in the exact same way

2.0.16
- changed model.dynamic attribute to an OpenStruct class which just makes it easier to work with
- changed dynamic_attach so that it now uses the model.dynamic attribute, instead of using singleton classes. This is better practice, and also contains all the moving parts of this gem in one place.
- added the dynamic_print method to easier see the objects one is working with.

2.0.21
- figured out how to add to a model's @attributes, so .dynamic OpenStruct no longer needed, no longer need dynamic_print, singletons are out aswell. unexpected columns for are now usable as just regular attributes.
- overrode inspect to show the dynamic attributes aswell, warning about passwords printed to logs etc.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/LukeClancy/dynamic-records-meritfront. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/LukeClancy/dynamic-records-meritfront/blob/master/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the ActiveRecordMeritfront project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/LukeClancy/dynamic-records-meritfront/blob/master/CODE_OF_CONDUCT.md).
