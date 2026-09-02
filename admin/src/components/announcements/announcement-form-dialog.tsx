'use client'

import { Plus } from 'lucide-react'
import { useActionState, useState } from 'react'
import { toast } from 'sonner'

import {
  createAnnouncementAction,
  initialActionState,
  updateAnnouncementAction,
  type ActionState,
} from '@/app/(dashboard)/announcements/actions'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from '@/components/ui/dialog'
import { Label } from '@/components/ui/label'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import {
  ANNOUNCEMENT_AUDIENCES,
  AUDIENCE_LABELS,
  BODY_MAX_LENGTH,
  isKnownAudience,
  TITLE_MAX_LENGTH,
  type Announcement,
} from '@/lib/announcements'

/**
 * Create and edit share one dialog: the fields are identical and only the action
 * and the hidden `id` differ.
 */
export function AnnouncementFormDialog({ announcement }: { announcement?: Announcement }) {
  const editing = announcement !== undefined
  const [open, setOpen] = useState(false)

  // The result is handled here rather than in an effect: an effect that closes the
  // dialog would fire a cascading render, and React lints it (set-state-in-effect).
  const [, formAction, pending] = useActionState(
    async (previous: ActionState, formData: FormData) => {
      const result = await (editing ? updateAnnouncementAction : createAnnouncementAction)(
        previous,
        formData,
      )
      if (result.status === 'success') {
        toast.success(result.message)
        setOpen(false)
      } else if (result.status === 'error') {
        toast.error(result.message)
      }
      return result
    },
    initialActionState,
  )

  const defaultAudience =
    announcement && isKnownAudience(announcement.audience) ? announcement.audience : 'all'

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        {editing ? (
          <Button variant="ghost" size="sm">
            Düzenle
          </Button>
        ) : (
          <Button size="sm">
            <Plus aria-hidden="true" />
            Yeni duyuru
          </Button>
        )}
      </DialogTrigger>

      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{editing ? 'Duyuruyu düzenle' : 'Yeni duyuru'}</DialogTitle>
          <DialogDescription>
            Duyurular herkese açık okunur. Hedef kitle istemcide filtrelenir; listedeki dört değer
            dışında bir değer hiçbir cihazda görünmez.
          </DialogDescription>
        </DialogHeader>

        <form action={formAction} className="flex flex-col gap-4">
          {editing ? <input type="hidden" name="id" value={announcement.id} /> : null}

          <div className="flex flex-col gap-2">
            <Label htmlFor="announcement-title">Başlık</Label>
            <Input
              id="announcement-title"
              name="title"
              required
              maxLength={TITLE_MAX_LENGTH}
              defaultValue={announcement?.title ?? ''}
              disabled={pending}
            />
          </div>

          <div className="flex flex-col gap-2">
            <Label htmlFor="announcement-body">Metin</Label>
            <Textarea
              id="announcement-body"
              name="body"
              required
              rows={6}
              maxLength={BODY_MAX_LENGTH}
              defaultValue={announcement?.body ?? ''}
              disabled={pending}
            />
          </div>

          <div className="flex flex-col gap-2">
            <Label htmlFor="announcement-audience">Hedef kitle</Label>
            <Select name="audience" defaultValue={defaultAudience} disabled={pending}>
              <SelectTrigger id="announcement-audience" className="w-full">
                <SelectValue placeholder="Seçin" />
              </SelectTrigger>
              <SelectContent>
                {ANNOUNCEMENT_AUDIENCES.map((audience) => (
                  <SelectItem key={audience} value={audience}>
                    {AUDIENCE_LABELS[audience]}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setOpen(false)} disabled={pending}>
              Vazgeç
            </Button>
            <Button type="submit" disabled={pending}>
              {pending ? 'Kaydediliyor…' : 'Kaydet'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
