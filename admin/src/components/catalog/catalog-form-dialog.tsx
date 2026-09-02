'use client'

import { Plus } from 'lucide-react'
import { useActionState, useState } from 'react'
import { toast } from 'sonner'

import {
  createCatalogServiceAction,
  initialActionState,
  updateCatalogServiceAction,
  type ActionState,
} from '@/app/(dashboard)/catalog/actions'
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
import {
  ISSUER_MAX_LENGTH,
  LOGO_URL_MAX_LENGTH,
  NAME_MAX_LENGTH,
  type CatalogService,
} from '@/lib/catalog'

export function CatalogFormDialog({ service }: { service?: CatalogService }) {
  const editing = service !== undefined
  const [open, setOpen] = useState(false)

  // Result handled inline, not in an effect (see announcement-form-dialog.tsx).
  const [, formAction, pending] = useActionState(
    async (previous: ActionState, formData: FormData) => {
      const result = await (editing ? updateCatalogServiceAction : createCatalogServiceAction)(
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
            Yeni servis
          </Button>
        )}
      </DialogTrigger>

      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>{editing ? 'Servisi düzenle' : 'Yeni servis'}</DialogTitle>
          <DialogDescription>
            Katalog, istemcide issuer adlarını kanonikleştirmek için kullanılır. Logo adresi
            saklanır ama uygulama çalışma anında logo indirmez (çevrimdışı + gizlilik kararı).
          </DialogDescription>
        </DialogHeader>

        <form action={formAction} className="flex flex-col gap-4">
          {editing ? <input type="hidden" name="id" value={service.id} /> : null}

          <div className="flex flex-col gap-2">
            <Label htmlFor="catalog-name">Ad</Label>
            <Input
              id="catalog-name"
              name="name"
              required
              maxLength={NAME_MAX_LENGTH}
              defaultValue={service?.name ?? ''}
              disabled={pending}
            />
          </div>

          <div className="flex flex-col gap-2">
            <Label htmlFor="catalog-issuer">Sağlayıcı (issuer)</Label>
            <Input
              id="catalog-issuer"
              name="issuer"
              maxLength={ISSUER_MAX_LENGTH}
              placeholder="Örn. github.com"
              defaultValue={service?.issuer ?? ''}
              disabled={pending}
            />
            <p className="text-muted-foreground text-xs">İsteğe bağlı.</p>
          </div>

          <div className="flex flex-col gap-2">
            <Label htmlFor="catalog-logo-url">Logo adresi</Label>
            <Input
              id="catalog-logo-url"
              name="logo_url"
              type="url"
              maxLength={LOGO_URL_MAX_LENGTH}
              placeholder="https://…"
              defaultValue={service?.logoUrl ?? ''}
              disabled={pending}
            />
            <p className="text-muted-foreground text-xs">
              İsteğe bağlı. Yalnızca mutlak <code>https://</code> adresleri kabul edilir.
            </p>
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
