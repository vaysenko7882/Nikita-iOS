"""One paced observer on the existing Telegram session; no extra logins."""
import asyncio
import hashlib
import json
import time
from telethon import errors, functions, types
from .media_capture import MediaCapture
from .profiles import public_value


class ProfileCollector:
    def __init__(self, client, store):
        self.client, self.store = client, store
        self.capture = MediaCapture(store.archive.media)
        self.gift_checks = {}
        self.avatar_ids = {}
        self.pause_until = 0
        self.request_lock = asyncio.Lock()
        self.last_request = 0

    async def request(self, value):
        async with self.request_lock:
            await asyncio.sleep(max(0,1-(time.monotonic()-self.last_request)))
            self.last_request = time.monotonic()
            return await self.client(value,flood_sleep_threshold=0)

    def user_update(self, update):
        peer_id = getattr(update,"user_id",None)
        if peer_id and self.store.enabled(peer_id):
            self.store.collection(peer_id,"notifications",{"_"+type(update).__name__:public_value(update)},complete=False)
            self.store.nudge(peer_id)

    def source(self, peer_id, section, item_id):
        self.capture.source = dict(type="CodeGramProfile",peer_id=peer_id,section=section,item_id=str(item_id))

    def photo(self, peer_id, section, photo):
        self.source(peer_id,section,photo.id)
        descriptor = self.capture.photo(photo,500)
        self.store.associate(peer_id,descriptor)
        return descriptor

    async def stories(self, peer_id, input_peer, selected=None):
        if selected is None:
            response = await self.request(functions.stories.GetPeerStoriesRequest(input_peer))
            stories = response.stories.stories
        else:
            stories = selected
        values, missing = {}, []
        for story in stories:
            if isinstance(story,types.StoryItemSkipped):
                missing.append(story.id)
        if missing:
            response = await self.request(functions.stories.GetStoriesByIDRequest(input_peer,missing))
            stories = [s for s in stories if not isinstance(s,types.StoryItemSkipped)] + list(response.stories)
        for story in stories:
            if not isinstance(story,types.StoryItem):
                continue
            self.source(peer_id,"stories",story.id)
            media = story.media
            descriptor = None
            if getattr(media,"photo",None):
                descriptor = self.capture.photo(media.photo,1000)
            elif getattr(media,"document",None):
                descriptor = self.capture.document(media.document,1000)
            self.store.associate(peer_id,descriptor)
            # Views/reactions are volatile counters; retain stable story metadata.
            item = public_value(story)
            for name in ("views","sent_reaction","media"):
                item.pop(name,None)
            item["media"] = descriptor
            values[str(story.id)] = item
        # A skipped/private item is not evidence that a saved story was deleted.
        self.store.collection(peer_id,"stories",values,complete=selected is None and not missing)

    async def gifts(self, peer_id, input_peer):
        offset, visited, gifts, positions = "", set(), {}, []
        count = 0
        while True:
            page = await self.request(functions.payments.GetSavedStarGiftsRequest(input_peer,offset,100))
            users = {user.id:user for user in page.users}
            count = page.count
            for gift in page.gifts:
                value = public_value(gift)
                sender = getattr(gift,"from_id",None)
                sender_id = None if getattr(gift,"name_hidden",False) else getattr(sender,"user_id",None)
                if getattr(gift,"name_hidden",False):
                    value["from_id"] = None
                sender_user = users.get(sender_id)
                if sender_user:
                    value["sender"] = dict(id=str(sender_user.id),first_name=sender_user.first_name,last_name=sender_user.last_name,username=sender_user.username)
                else:
                    value["sender"] = None
                # Mutable display/pin flags must not turn an existing gift into a new one.
                source_gift = getattr(gift,"gift",None)
                stable = dict(gift_id=getattr(source_gift,"id",None),date=value.get("date"))
                base = str(getattr(gift,"saved_id",None) or getattr(gift,"msg_id",None) or
                           ("unique:"+str(source_gift.id) if getattr(source_gift,"slug",None) else
                            hashlib.sha256(json.dumps(stable,sort_keys=True).encode()).hexdigest()))
                key, duplicate = base, 0
                while key in gifts:
                    duplicate += 1; key = base+":"+str(duplicate)
                self.source(peer_id,"gifts",key)
                sticker = getattr(getattr(gift,"gift",None),"sticker",None)
                if sticker:
                    value["artwork"] = self.capture.document(sticker,10)
                    self.store.associate(peer_id,value["artwork"])
                gifts[key] = value
                positions.append(key)
            next_offset = getattr(page,"next_offset",None)
            if not next_offset:
                break
            if next_offset in visited:
                raise ValueError("Repeated gift page")
            visited.add(next_offset)
            offset = next_offset
            await asyncio.sleep(0.5)
            if not self.store.enabled(peer_id):
                return
        self.store.collection(peer_id,"gifts",gifts)
        self.store.collection(peer_id,"gifts",{"_visible_order":dict(count=count,order=positions)},complete=False)
        self.gift_checks[peer_id] = time.monotonic()

    async def avatars(self, peer_id, input_peer, signature, extra):
        photos, order = {}, []
        for role,photo in extra:
            if isinstance(photo,types.Photo):
                photos[str(photo.id)] = dict(id=str(photo.id),date=public_value(photo.date),media=self.photo(peer_id,"avatars",photo))
        async for photo in self.client.iter_profile_photos(input_peer):
            order.append(str(photo.id))
            photos[str(photo.id)] = dict(id=str(photo.id),date=public_value(photo.date),media=self.photo(peer_id,"avatars",photo))
            if len(order)%100==0:
                await asyncio.sleep(0.5)
            if not self.store.enabled(peer_id):
                return
        self.store.collection(peer_id,"avatars",photos)
        self.avatar_ids[peer_id] = signature

    async def scan(self, peer_id, access_hash):
        input_peer = types.InputPeerUser(peer_id,int(access_hash))
        full = await self.request(functions.users.GetFullUserRequest(types.InputUser(peer_id,int(access_hash))))
        user = next(user for user in full.users if user.id==peer_id)
        info = full.full_user
        photo_id = getattr(getattr(user,"photo",None),"photo_id",None)
        fields = {name:public_value(getattr(user,name,None)) for name in
                  ("first_name","last_name","username","usernames","premium","verified","scam","fake","emoji_status","color","profile_color")}
        fields.update({name:public_value(getattr(info,name,None)) for name in
                       ("about","birthday","personal_channel_id","personal_channel_message","business_work_hours","business_location","business_intro","stargifts_count","saved_music","main_tab","stars_rating","disallowed_gifts","phone_calls_available","phone_calls_private","video_calls_available","voice_messages_forbidden","contact_require_premium","send_paid_messages_stars")})
        fields["current_photo_id"] = str(photo_id) if photo_id else None
        extra_photos = [(role,getattr(info,role,None)) for role in ("profile_photo","fallback_photo","personal_photo")]
        signature = (photo_id,)+tuple(getattr(photo,"id",None) for _,photo in extra_photos)
        fields["fallback_photo_id"] = str(signature[2]) if signature[2] else None
        fields["personal_photo_id"] = str(signature[3]) if signature[3] else None
        self.store.fields(peer_id,fields)
        status = type(getattr(user,"status",None)).__name__
        last_seen = "visible" if status in ("UserStatusOnline","UserStatusOffline") else status
        self.store.collection(peer_id,"availability",{"current":dict(
            profile_request="ok",photo_visible=bool(photo_id or signature[2]),about_visible=bool(getattr(info,"about",None)),
            last_seen_visibility=last_seen,account_deleted=bool(getattr(user,"deleted",False)),
            blocked_by_me=bool(getattr(info,"blocked",False)),
            blocked_by_target="unknown_not_exposed_by_telegram",
            note="Доступность фото, описания и статуса не доказывает блокировку: она также зависит от настроек приватности."
        )},complete=False)
        # Active stories first: fetch only what this session can actually see.
        warnings = []
        operations = [("Сторис",lambda: self.stories(peer_id,input_peer))]
        if peer_id not in self.avatar_ids or self.avatar_ids[peer_id] != signature:
            operations.append(("Аватарки",lambda: self.avatars(peer_id,input_peer,signature,extra_photos)))
        if time.monotonic()-self.gift_checks.get(peer_id,-100000)>=300:
            operations.append(("Подарки",lambda: self.gifts(peer_id,input_peer)))
        for name,operation in operations:
            if not self.store.enabled(peer_id):
                return ""
            try:
                await operation()
            except errors.FloodWaitError:
                raise
            except Exception as error:
                # A restricted collection never blocks unrelated profile changes.
                warnings.append(name+": "+type(error).__name__)
        return "; ".join(warnings)

    async def pushed_story(self, update):
        peer = getattr(update,"peer",None)
        peer_id = getattr(peer,"user_id",None)
        if peer_id and self.store.enabled(peer_id):
            story = getattr(update,"story",None)
            if isinstance(story,types.StoryItem):
                await self.stories(peer_id,None,[story])

    async def run(self):
        while True:
            if time.monotonic() < self.pause_until:
                await asyncio.sleep(min(30,self.pause_until-time.monotonic()))
                continue
            for peer_id,access_hash in self.store.due():
                try:
                    warning = await self.scan(peer_id,access_hash)
                    self.store.checked(peer_id,warning or "")
                except errors.FloodWaitError as error:
                    delay = max(30,int(error.seconds)+2)
                    self.pause_until = time.monotonic()+delay
                    self.store.checked(peer_id,"Telegram временно ограничил запросы",delay=delay)
                    break
                except Exception as error:
                    # No usernames, bio, credentials or attachment references in logs.
                    if type(error).__name__ in ("UserPrivacyRestrictedError","UserIdInvalidError","InputUserDeactivatedError"):
                        self.store.collection(peer_id,"availability",{"current":dict(profile_request="unavailable",reason=type(error).__name__,blocked_by_target="unknown_not_exposed_by_telegram")},complete=False)
                    self.store.checked(peer_id,type(error).__name__,delay=300)
                await asyncio.sleep(1)
            await asyncio.sleep(5)
