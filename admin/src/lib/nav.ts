/**
 * Sidebar navigation contract.
 *
 * Routes listed here may not exist yet — later workers add them under
 * `src/app/(dashboard)/…`. Adding a page means adding its entry here, nothing else.
 */
export interface NavItem {
  href: string
  label: string
}

export const NAV_ITEMS: readonly NavItem[] = [
  { href: '/', label: 'Panel' },
  { href: '/users', label: 'Kullanıcılar' },
  { href: '/announcements', label: 'Duyurular' },
  { href: '/catalog', label: 'Katalog' },
  { href: '/flags', label: 'Bayraklar' },
  { href: '/audit', label: 'Denetim Kaydı' },
] as const
