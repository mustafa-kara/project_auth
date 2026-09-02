import type { Metadata } from 'next'

import { LoginForm } from '@/app/login/login-form'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'

export const metadata: Metadata = {
  title: 'Giriş — Yönetim Paneli',
}

export default function LoginPage() {
  return (
    <div className="flex flex-1 items-center justify-center p-6">
      <Card className="w-full max-w-sm">
        <CardHeader>
          <CardTitle>Yönetim Paneli</CardTitle>
          <CardDescription>Yalnızca yönetici hesapları giriş yapabilir.</CardDescription>
        </CardHeader>
        <CardContent>
          <LoginForm />
        </CardContent>
      </Card>
    </div>
  )
}
