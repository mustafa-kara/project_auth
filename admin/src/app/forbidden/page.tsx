import type { Metadata } from 'next'

import { SignOutButton } from '@/components/sign-out-button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'

export const metadata: Metadata = {
  title: 'Yetkisiz erişim — Yönetim Paneli',
}

export default function ForbiddenPage() {
  return (
    <div className="flex flex-1 items-center justify-center p-6">
      <Card className="w-full max-w-sm">
        <CardHeader>
          <CardTitle>Bu hesap yönetici değil</CardTitle>
          <CardDescription>
            Oturumunuz geçerli, ancak hesabınızda yönetici yetkisi yok. Başka bir hesapla giriş
            yapın.
          </CardDescription>
        </CardHeader>
        <CardContent>
          <SignOutButton />
        </CardContent>
      </Card>
    </div>
  )
}
