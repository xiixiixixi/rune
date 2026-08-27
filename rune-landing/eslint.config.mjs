import { FlatCompat } from "@eslint/eslintrc"

const compat = new FlatCompat({ baseDirectory: import.meta.dirname })

const config = [
  ...compat.extends("next/core-web-vitals", "next/typescript"),
  {
    ignores: [
      ".next/**",
      "out/**",
      "node_modules/**",
      "components/ui/toaster.tsx",
      "components/ui/use-toast.ts",
      "hooks/use-toast.ts",
    ],
  },
]

export default config
