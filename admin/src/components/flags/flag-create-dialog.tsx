'use client'

import { Plus } from 'lucide-react'
import { useActionState, useState } from 'react'
import { toast } from 'sonner'

import {
  createFlagAction,
  initialActionState,
  type ActionState,
} from '@/app/(dashboard)/flags/actions'
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
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Switch } from '@/components/ui/switch'
import { Textarea } from '@/components/ui/textarea'
import { PAYLOAD_MAX_BYTES } from '@/lib/flags'

export function FlagCreateDialog() {
  const [open, setOpen] = useState(false)
  const [enabled, setEnabled] = useState(false)

  // Result handled inline, not in an effect (see announcement-form-dialog.tsx).
  const [, formAction, pending] = useActionState(
    async (previous: ActionState, formData: FormData) => {
      const result = await createFlagAction(previous, formData)
      if (result.status === 'success') {
        toast.success(result.message)
        setOpen(false)
        setEnabled(false)
      } else if (result.status === 'error') {
        toast.error(result.message)
      }
      return result
    },
    initialActionState,
  )

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button size="sm">
          <Plus aria-hidden="true" />
          Yeni bayrak
        </Button>
      </DialogTrigger>

      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>Yeni bayrak</DialogTitle>
          <DialogDescription>
            Anahtar küçük harfle başlar; küçük harf, rakam ve alt çizgi içerir (3–64 karakter).
            İstemci bilmediği anahtarları yok sayar.
          </DialogDescription>
        </DialogHeader>

        <form action={formAction} className="flex flex-col gap-4">
          {/* The Switch is not a native input; its value travels in this hidden field. */}
          <input type="hidden" name="enabled" value={enabled ? 'true' : 'false'} />

          <div className="flex flex-col gap-2">
            <Label htmlFor="flag-key">Anahtar</Label>
            <Input
              id="flag-key"
              name="key"
              required
              className="font-mono"
              placeholder="ornek_bayrak"
              disabled={pending}
            />
          </div>

          <div className="flex items-center justify-between gap-4 rounded-md border p-3">
            <Label htmlFor="flag-enabled" className="font-normal">
              Başlangıçta açık
            </Label>
            <Switch
              id="flag-enabled"
              checked={enabled}
              onCheckedChange={setEnabled}
              disabled={pending}
            />
          </div>

          <div className="flex flex-col gap-2">
            <Label htmlFor="flag-payload">Payload (JSON, isteğe bağlı)</Label>
            <Textarea
              id="flag-payload"
              name="payload"
              rows={6}
              spellCheck={false}
              className="font-mono text-xs"
              placeholder="{}"
              disabled={pending}
            />
            <p className="text-muted-foreground text-xs">
              Boş bırakılırsa NULL yazılır. En fazla {PAYLOAD_MAX_BYTES / 1024} KiB, JSON nesnesi.
            </p>
          </div>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => setOpen(false)} disabled={pending}>
              Vazgeç
            </Button>
            <Button type="submit" disabled={pending}>
              {pending ? 'Oluşturuluyor…' : 'Oluştur'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
