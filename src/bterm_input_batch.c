/* Atomic host input over the existing native encoders. No parser or UI policy. */
#include "bterm_internal.h"
#include <stdlib.h>
bool bterm_send_events(bterm *t,const bterm_input_event *events,size_t count,
                      bool (*send)(void *,const uint8_t *,size_t),void *context,size_t *length) {
  if(!length)return false;
  *length=0;
  if(!t || !events || !count || count>BTERM_INPUT_EVENTS || !send)return false;
  size_t text_bytes=0;
  for(size_t i=0;i<count;i++) {
    size_t n=events[i].kind==BT_INPUT_KEY ? events[i].key.text_length : events[i].kind==BT_INPUT_PASTE ? events[i].text_length : 0;
    if(n>BTERM_INPUT_BYTES-text_bytes)return false;
    text_bytes+=n;
  }
  uint8_t *output=malloc(BTERM_INPUT_BYTES);if(!output)return false;
  bool focused=t->focused; bmouse_motion motion=t->mouse_motion;
  uint32_t width=t->mouse_cell_width,height=t->mouse_cell_height;
  size_t used=0;bool ok=true;
  for(size_t i=0;i<count && ok;i++) {
    const bterm_input_event *event=&events[i];size_t n=0,remaining=BTERM_INPUT_BYTES-used;
    switch(event->kind) {
      case BT_INPUT_KEY:ok=bterm_key(t,&event->key,event->macos,event->option_as_alt,output+used,remaining,&n);break;
      case BT_INPUT_PASTE:ok=bterm_paste(t,event->text,event->text_length,output+used,remaining,&n);break;
      case BT_INPUT_FOCUS:ok=bterm_focus(t,event->focused,output+used,remaining,&n);break;
      case BT_INPUT_MOUSE:ok=bterm_mouse(t,&event->mouse,event->cell_width,event->cell_height,output+used,remaining,&n);break;
      default:ok=false;break;
    }
    if(ok)used+=n;
  }
  if(ok)ok=send(context,output,used);
  if(!ok){t->focused=focused;t->mouse_motion=motion;t->mouse_cell_width=width;t->mouse_cell_height=height;}
  else *length=used;
  free(output);return ok;
}
