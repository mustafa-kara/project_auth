'use client'

import { useState, useTransition } from 'react'
import { toast } from 'sonner'

import { deleteAnnouncementAction } from '@/app/(dashboard)/announcements/actions'
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog'
import { Button } from '@/components/ui/button'
import type { Announcement } from '@/lib/announcements'

export function DeleteAnnouncementDialog({ announcement }: { announcement: Announcement }) {
  const [open, setOpen] = useState(false)
  const [pending, startTransition] = useTransition()

  function confirm() {
    startTransition(async () => {
      const result = await deleteAnnouncementAction(announcement.id)
      if (result.status === 'success') {
        toast.success(result.message)
        setOpen(false)
      } else if (result.status === 'error') {
        toast.error(result.message)
      }
    })
  }

  return (
    <AlertDialog open={open} onOpenChange={setOpen}>
      <AlertDialogTrigger asChild>
        <Button variant="ghost" size="sm" className="text-destructive hover:text-destructive">
          Sil
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>Duyuru silinsin mi?</AlertDialogTitle>
          <AlertDialogDescription>
            “{announcement.title}” kalıcı olarak silinecek. Bu işlem geri alınamaz.
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel disabled={pending}>Vazgeç</AlertDialogCancel>
          <AlertDialogAction
            onClick={(event) => {
              event.preventDefault()
              confirm()
            }}
            disabled={pending}
          >
            {pending ? 'Siliniyor…' : 'Sil'}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}
