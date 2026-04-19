-- ══════════════════════════════════════════
-- QR CERTIFY — Setup complet nouveau projet
-- Supabase Dashboard > SQL Editor > New query > coller > Run
-- ══════════════════════════════════════════

-- ── 1. Table profils utilisateurs ────────
CREATE TABLE IF NOT EXISTS profiles (
  id          UUID        REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  email       TEXT,
  name        TEXT,
  avatar_url  TEXT,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;

-- Trigger : créer automatiquement un profil à l'inscription
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO profiles (id, email, name)
  VALUES (NEW.id, NEW.email, NEW.raw_user_meta_data->>'name')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ── 2. Table des rôles ───────────────────
CREATE TABLE IF NOT EXISTS user_roles (
  user_id    UUID  REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  role       TEXT  NOT NULL DEFAULT 'user' CHECK (role IN ('user', 'admin')),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;

CREATE POLICY "read_own_role" ON user_roles
  FOR SELECT USING (auth.uid() = user_id);

-- ── 3. Fonction is_admin() ───────────────
CREATE OR REPLACE FUNCTION is_admin()
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM user_roles
    WHERE user_id = auth.uid() AND role = 'admin'
  );
$$;

-- ── 4. Policies profiles ─────────────────
CREATE POLICY "read_profiles" ON profiles
  FOR SELECT USING (auth.uid() = id OR is_admin());

CREATE POLICY "update_own_profile" ON profiles
  FOR UPDATE USING (auth.uid() = id);

-- ── 5. Table liens certifiés ─────────────
CREATE TABLE IF NOT EXISTS certified_links (
  id         UUID        DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id    UUID        REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  url        TEXT        NOT NULL,
  domain     TEXT,
  score      INTEGER,
  label      TEXT,
  note       TEXT,
  source     TEXT        DEFAULT 'local',
  global     BOOLEAN     NOT NULL DEFAULT false,   -- true = certifié officiellement par admin
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cl_user_id    ON certified_links(user_id);
CREATE INDEX IF NOT EXISTS idx_cl_created_at ON certified_links(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cl_global_url ON certified_links(url) WHERE global = true;

ALTER TABLE certified_links ENABLE ROW LEVEL SECURITY;

-- Utilisateurs voient leurs propres lignes + toutes les lignes globales
CREATE POLICY "select_own" ON certified_links
  FOR SELECT USING (auth.uid() = user_id OR global = true OR is_admin());

-- Utilisateurs insèrent uniquement leurs propres lignes non-globales ; admin peut insérer global
CREATE POLICY "insert_own" ON certified_links
  FOR INSERT WITH CHECK (
    auth.uid() = user_id
    AND (global = false OR is_admin())
  );

CREATE POLICY "update_own" ON certified_links
  FOR UPDATE USING (auth.uid() = user_id OR is_admin());

CREATE POLICY "delete_own" ON certified_links
  FOR DELETE USING (auth.uid() = user_id OR is_admin());

-- ── 6. Table votes utilisateurs ─────────
CREATE TABLE IF NOT EXISTS link_votes (
  id         UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id    UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  url        TEXT NOT NULL,
  domain     TEXT,
  vote       TEXT NOT NULL CHECK (vote IN ('safe', 'unsafe')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, url)
);

CREATE INDEX IF NOT EXISTS idx_lv_url ON link_votes(url);

ALTER TABLE link_votes ENABLE ROW LEVEL SECURITY;

-- Tout utilisateur connecté peut voir les votes (pour calculer les totaux)
CREATE POLICY "select_votes" ON link_votes
  FOR SELECT USING (auth.uid() IS NOT NULL);

-- Chaque utilisateur peut voter (insérer/modifier son propre vote)
CREATE POLICY "insert_own_vote" ON link_votes
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY "update_own_vote" ON link_votes
  FOR UPDATE USING (auth.uid() = user_id);

-- Utilisateur ou admin peut supprimer
CREATE POLICY "delete_vote" ON link_votes
  FOR DELETE USING (auth.uid() = user_id OR is_admin());

-- ── 7. Promouvoir en admin ───────────────
-- Après t'être inscrit dans l'app, récupère ton UUID dans
-- Authentication > Users, puis lance :
-- INSERT INTO user_roles (user_id, role)
-- VALUES ('ton-uuid-ici', 'admin')
-- ON CONFLICT (user_id) DO UPDATE SET role = 'admin';
