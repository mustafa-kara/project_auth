# Servis logoları — simple-icons (CC0)

Bu klasördeki SVG ikonları [simple-icons](https://github.com/simple-icons/simple-icons)
projesinden alınmıştır.

- **Lisans:** CC0 1.0 Universal (public domain) — kaynaktan teyit edildi
  (`simple-icons/simple-icons` → `LICENSE.md` başlığı "CC0 1.0 Universal").
- **Kullanım:** tek-renkli SVG'ler; uygulamada tema rengiyle (`currentColor`/tint)
  boyanır. `IssuerAvatar` issuer adını slug'a normalize edip eşleşen SVG'yi gösterir;
  eşleşmezse baş-harf + renkli daire fallback'ine düşer.
- **Curated alt-küme:** Bundle boyutunu küçük tutmak için yalnız yaygın servisler
  gömülüdür (bkz. `docs/Design.md §6, §7`). Eşleşmeyen tüm issuer'lar fallback kullanır.
- **Offline + gizlilik:** runtime logo/favicon çekme YAPILMAZ; tüm ikonlar bundle'dan.

Yeni ikon eklemek için: `https://raw.githubusercontent.com/simple-icons/simple-icons/master/icons/<slug>.svg`
indir, bu klasöre koy (slug = lowercase servis adı).
