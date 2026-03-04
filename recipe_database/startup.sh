#!/bin/bash

# PostgreSQL startup script for Culinary Companion database
# Flow: StartDatabaseFlow
# Contract:
#   Input: None (uses hardcoded config below)
#   Output: Running PostgreSQL on DB_PORT with schema and seed data
#   Side effects: Creates DB, user, tables, indexes, and seed data
DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5000"

echo "Starting PostgreSQL setup..."

# Find PostgreSQL version and set paths
PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

echo "Found PostgreSQL version: ${PG_VERSION}"

# Check if PostgreSQL is already running on the specified port
if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
    echo "PostgreSQL is already running on port ${DB_PORT}!"
    echo "Database: ${DB_NAME}"
    echo "User: ${DB_USER}"
    echo "Port: ${DB_PORT}"
    echo ""
    echo "To connect to the database, use:"
    echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
    
    if [ -f "db_connection.txt" ]; then
        echo "Or use: $(cat db_connection.txt)"
    fi
    
    echo ""
    echo "Script stopped - server already running."
    exit 0
fi

# Also check if there's a PostgreSQL process running (in case pg_isready fails)
if pgrep -f "postgres.*-p ${DB_PORT}" > /dev/null 2>&1; then
    echo "Found existing PostgreSQL process on port ${DB_PORT}"
    echo "Attempting to verify connection..."
    
    if sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} -c '\q' 2>/dev/null; then
        echo "Database ${DB_NAME} is accessible."
        echo "Script stopped - server already running."
        exit 0
    fi
fi

# Initialize PostgreSQL data directory if it doesn't exist
if [ ! -f "/var/lib/postgresql/data/PG_VERSION" ]; then
    echo "Initializing PostgreSQL..."
    sudo -u postgres ${PG_BIN}/initdb -D /var/lib/postgresql/data
fi

# Start PostgreSQL server in background
echo "Starting PostgreSQL server..."
sudo -u postgres ${PG_BIN}/postgres -D /var/lib/postgresql/data -p ${DB_PORT} &

# Wait for PostgreSQL to start
echo "Waiting for PostgreSQL to start..."
sleep 5

# Check if PostgreSQL is running
for i in {1..15}; do
    if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
        echo "PostgreSQL is ready!"
        break
    fi
    echo "Waiting... ($i/15)"
    sleep 2
done

# Create database and user
echo "Setting up database and user..."
sudo -u postgres ${PG_BIN}/createdb -p ${DB_PORT} ${DB_NAME} 2>/dev/null || echo "Database might already exist"

# Set up user and permissions with proper schema ownership
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d postgres << EOF
-- Create user if doesn't exist
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
    END IF;
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
END
\$\$;

-- Grant database-level permissions
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};

-- Connect to the specific database for schema-level permissions
\c ${DB_NAME}

GRANT USAGE ON SCHEMA public TO ${DB_USER};
GRANT CREATE ON SCHEMA public TO ${DB_USER};

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};

GRANT ALL ON SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DB_USER};
EOF

# Additionally, connect to the specific database to ensure permissions
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} << EOF
GRANT ALL ON SCHEMA public TO ${DB_USER};
GRANT CREATE ON SCHEMA public TO ${DB_USER};
\dn+ public
EOF

# ============================================================
# Schema creation (idempotent - uses IF NOT EXISTS)
# ============================================================
echo "Creating database schema..."

PGPASSWORD="${DB_PASSWORD}" ${PG_BIN}/psql -h localhost -p ${DB_PORT} -U ${DB_USER} -d ${DB_NAME} << 'SCHEMA_EOF'
-- Users table: stores account info and roles
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(100) NOT NULL UNIQUE,
    email VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255) NOT NULL,
    display_name VARCHAR(150),
    bio TEXT,
    avatar_url VARCHAR(500),
    role VARCHAR(20) NOT NULL DEFAULT 'user',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Categories table: recipe categories (e.g., Appetizers, Desserts)
CREATE TABLE IF NOT EXISTS categories (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL UNIQUE,
    description TEXT,
    image_url VARCHAR(500),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Cuisines table: cuisine types (e.g., Italian, Mexican)
CREATE TABLE IF NOT EXISTS cuisines (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL UNIQUE,
    description TEXT,
    image_url VARCHAR(500),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Recipes table: core recipe data
CREATE TABLE IF NOT EXISTS recipes (
    id SERIAL PRIMARY KEY,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    instructions TEXT NOT NULL,
    prep_time_minutes INTEGER,
    cook_time_minutes INTEGER,
    total_time_minutes INTEGER,
    servings INTEGER,
    difficulty VARCHAR(20) DEFAULT 'medium',
    image_url VARCHAR(500),
    is_published BOOLEAN NOT NULL DEFAULT TRUE,
    is_approved BOOLEAN NOT NULL DEFAULT TRUE,
    author_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
    cuisine_id INTEGER REFERENCES cuisines(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Ingredients table: recipe ingredients with quantities
CREATE TABLE IF NOT EXISTS ingredients (
    id SERIAL PRIMARY KEY,
    recipe_id INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
    name VARCHAR(200) NOT NULL,
    quantity VARCHAR(50),
    unit VARCHAR(50),
    order_index INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Recipe steps: ordered instructions for each recipe
CREATE TABLE IF NOT EXISTS recipe_steps (
    id SERIAL PRIMARY KEY,
    recipe_id INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
    step_number INTEGER NOT NULL,
    instruction TEXT NOT NULL,
    image_url VARCHAR(500),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Favorites: user-recipe bookmark relationship
CREATE TABLE IF NOT EXISTS favorites (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipe_id INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE(user_id, recipe_id)
);

-- Ratings: 1-5 star ratings per user per recipe
CREATE TABLE IF NOT EXISTS ratings (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipe_id INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
    score INTEGER NOT NULL CHECK (score >= 1 AND score <= 5),
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE(user_id, recipe_id)
);

-- Reviews: text reviews for recipes
CREATE TABLE IF NOT EXISTS reviews (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipe_id INTEGER NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
    comment TEXT NOT NULL,
    is_approved BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Shopping lists: named lists per user
CREATE TABLE IF NOT EXISTS shopping_lists (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name VARCHAR(200) NOT NULL DEFAULT 'My Shopping List',
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Shopping list items: individual items in a shopping list
CREATE TABLE IF NOT EXISTS shopping_list_items (
    id SERIAL PRIMARY KEY,
    shopping_list_id INTEGER NOT NULL REFERENCES shopping_lists(id) ON DELETE CASCADE,
    ingredient_name VARCHAR(200) NOT NULL,
    quantity VARCHAR(50),
    unit VARCHAR(50),
    is_checked BOOLEAN NOT NULL DEFAULT FALSE,
    recipe_id INTEGER REFERENCES recipes(id) ON DELETE SET NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Moderation log: admin actions for content moderation
CREATE TABLE IF NOT EXISTS moderation_log (
    id SERIAL PRIMARY KEY,
    admin_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    target_type VARCHAR(50) NOT NULL,
    target_id INTEGER NOT NULL,
    action VARCHAR(50) NOT NULL,
    reason TEXT,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Indexes for query performance
CREATE INDEX IF NOT EXISTS idx_recipes_author_id ON recipes(author_id);
CREATE INDEX IF NOT EXISTS idx_recipes_category_id ON recipes(category_id);
CREATE INDEX IF NOT EXISTS idx_recipes_cuisine_id ON recipes(cuisine_id);
CREATE INDEX IF NOT EXISTS idx_recipes_is_published ON recipes(is_published);
CREATE INDEX IF NOT EXISTS idx_recipes_title ON recipes(title);
CREATE INDEX IF NOT EXISTS idx_ingredients_recipe_id ON ingredients(recipe_id);
CREATE INDEX IF NOT EXISTS idx_recipe_steps_recipe_id ON recipe_steps(recipe_id);
CREATE INDEX IF NOT EXISTS idx_favorites_user_id ON favorites(user_id);
CREATE INDEX IF NOT EXISTS idx_favorites_recipe_id ON favorites(recipe_id);
CREATE INDEX IF NOT EXISTS idx_ratings_recipe_id ON ratings(recipe_id);
CREATE INDEX IF NOT EXISTS idx_ratings_user_id ON ratings(user_id);
CREATE INDEX IF NOT EXISTS idx_reviews_recipe_id ON reviews(recipe_id);
CREATE INDEX IF NOT EXISTS idx_reviews_user_id ON reviews(user_id);
CREATE INDEX IF NOT EXISTS idx_shopping_lists_user_id ON shopping_lists(user_id);
CREATE INDEX IF NOT EXISTS idx_shopping_list_items_list_id ON shopping_list_items(shopping_list_id);
CREATE INDEX IF NOT EXISTS idx_moderation_log_admin_id ON moderation_log(admin_id);
CREATE INDEX IF NOT EXISTS idx_moderation_log_target ON moderation_log(target_type, target_id);
SCHEMA_EOF

echo "Schema creation complete!"

# ============================================================
# Seed data (only if users table is empty)
# ============================================================
USER_COUNT=$(PGPASSWORD="${DB_PASSWORD}" ${PG_BIN}/psql -h localhost -p ${DB_PORT} -U ${DB_USER} -d ${DB_NAME} -t -c "SELECT COUNT(*) FROM users;" 2>/dev/null | tr -d ' ')

if [ "$USER_COUNT" = "0" ] || [ -z "$USER_COUNT" ]; then
    echo "Inserting seed data..."

    PGPASSWORD="${DB_PASSWORD}" ${PG_BIN}/psql -h localhost -p ${DB_PORT} -U ${DB_USER} -d ${DB_NAME} << 'SEED_EOF'
-- Seed users (password hash is for "password123" using bcrypt)
INSERT INTO users (username, email, password_hash, display_name, bio, role) VALUES
('admin', 'admin@culinarycompanion.com', '$2b$12$LJ3m4ys3Lz0QxMOFKnGJHeYBnOJcGViKbxMXqKpfOqpxBwBHNRBKi', 'Admin User', 'Platform administrator', 'admin'),
('chef_maria', 'maria@example.com', '$2b$12$LJ3m4ys3Lz0QxMOFKnGJHeYBnOJcGViKbxMXqKpfOqpxBwBHNRBKi', 'Chef Maria', 'Professional chef with 15 years experience', 'user'),
('homecook_joe', 'joe@example.com', '$2b$12$LJ3m4ys3Lz0QxMOFKnGJHeYBnOJcGViKbxMXqKpfOqpxBwBHNRBKi', 'Joe the Home Cook', 'Passionate home cook and food blogger', 'user')
ON CONFLICT (username) DO NOTHING;

-- Seed categories
INSERT INTO categories (name, description) VALUES
('Appetizers', 'Small dishes served before the main course'),
('Main Course', 'Primary dishes for lunch or dinner'),
('Desserts', 'Sweet dishes served after the main course'),
('Soups', 'Hot or cold liquid-based dishes'),
('Salads', 'Fresh vegetable and mixed dishes'),
('Breakfast', 'Morning meal dishes'),
('Snacks', 'Light bites between meals'),
('Beverages', 'Drinks and smoothies')
ON CONFLICT (name) DO NOTHING;

-- Seed cuisines
INSERT INTO cuisines (name, description) VALUES
('Italian', 'Cuisine from Italy known for pasta, pizza, and rich flavors'),
('Mexican', 'Vibrant cuisine featuring tacos, burritos, and bold spices'),
('Japanese', 'Cuisine emphasizing fresh ingredients and precise technique'),
('Indian', 'Rich and diverse cuisine with aromatic spices'),
('French', 'Classic European cuisine known for refined techniques'),
('Chinese', 'Diverse regional cuisine with stir-frying and steaming'),
('American', 'Hearty comfort foods and melting pot of cultures'),
('Thai', 'Cuisine balancing sweet, sour, salty, and spicy flavors'),
('Mediterranean', 'Healthy cuisine featuring olive oil, fresh produce, and seafood'),
('Korean', 'Cuisine known for kimchi, BBQ, and fermented dishes')
ON CONFLICT (name) DO NOTHING;

-- Seed recipes
INSERT INTO recipes (title, description, instructions, prep_time_minutes, cook_time_minutes, total_time_minutes, servings, difficulty, author_id, category_id, cuisine_id) VALUES
('Classic Margherita Pizza', 'A traditional Italian pizza with fresh mozzarella, tomatoes, and basil', 'Make dough, add sauce, top with mozzarella and basil, bake at 450F for 12-15 minutes.', 30, 15, 45, 4, 'medium', 2, 2, 1),
('Chicken Tikka Masala', 'Tender chicken pieces in a creamy spiced tomato sauce', 'Marinate chicken, grill until charred, simmer in masala sauce with cream and spices for 20 minutes.', 40, 30, 70, 4, 'medium', 2, 2, 4),
('Japanese Miso Soup', 'Light and savory traditional Japanese soup with tofu and seaweed', 'Dissolve miso paste in dashi stock, add cubed tofu and wakame seaweed, heat gently without boiling.', 10, 10, 20, 4, 'easy', 3, 4, 3),
('Beef Tacos', 'Authentic Mexican street tacos with seasoned beef and fresh toppings', 'Season and brown beef, warm tortillas, assemble with onion, cilantro, salsa, and lime.', 15, 15, 30, 6, 'easy', 3, 2, 2),
('Chocolate Lava Cake', 'Rich chocolate cake with a molten center', 'Melt chocolate and butter, whisk eggs and sugar, fold together, pour into ramekins, bake at 425F for 12 minutes.', 20, 12, 32, 4, 'hard', 2, 3, 5),
('Caesar Salad', 'Classic Caesar salad with homemade dressing and croutons', 'Prepare dressing with anchovy, garlic, lemon, and parmesan. Toss romaine lettuce, add croutons and shaved parmesan.', 20, 5, 25, 2, 'easy', 3, 5, 7);

-- Seed ingredients
INSERT INTO ingredients (recipe_id, name, quantity, unit, order_index) VALUES
(1, 'Pizza dough', '1', 'ball', 1), (1, 'San Marzano tomatoes', '1', 'cup', 2), (1, 'Fresh mozzarella', '8', 'oz', 3),
(1, 'Fresh basil leaves', '10', 'leaves', 4), (1, 'Olive oil', '2', 'tbsp', 5), (1, 'Salt', '1', 'tsp', 6),
(2, 'Chicken breast', '1.5', 'lbs', 1), (2, 'Yogurt', '0.5', 'cup', 2), (2, 'Garam masala', '2', 'tsp', 3),
(2, 'Tomato puree', '1', 'cup', 4), (2, 'Heavy cream', '0.5', 'cup', 5), (2, 'Onion', '1', 'large', 6),
(2, 'Garlic', '4', 'cloves', 7), (2, 'Ginger', '1', 'inch', 8),
(3, 'Dashi stock', '4', 'cups', 1), (3, 'Miso paste', '3', 'tbsp', 2), (3, 'Silken tofu', '200', 'g', 3),
(3, 'Wakame seaweed', '2', 'tbsp', 4), (3, 'Green onion', '2', 'stalks', 5),
(4, 'Ground beef', '1', 'lb', 1), (4, 'Corn tortillas', '12', 'pieces', 2), (4, 'White onion', '1', 'medium', 3),
(4, 'Fresh cilantro', '0.5', 'cup', 4), (4, 'Lime', '2', 'whole', 5), (4, 'Salsa verde', '0.5', 'cup', 6),
(4, 'Cumin', '1', 'tsp', 7), (4, 'Chili powder', '1', 'tsp', 8),
(5, 'Dark chocolate', '6', 'oz', 1), (5, 'Unsalted butter', '0.5', 'cup', 2), (5, 'Eggs', '2', 'large', 3),
(5, 'Egg yolks', '2', 'large', 4), (5, 'Sugar', '0.25', 'cup', 5), (5, 'All-purpose flour', '2', 'tbsp', 6),
(6, 'Romaine lettuce', '2', 'hearts', 1), (6, 'Parmesan cheese', '0.5', 'cup', 2), (6, 'Croutons', '1', 'cup', 3),
(6, 'Anchovy fillets', '3', 'pieces', 4), (6, 'Garlic', '2', 'cloves', 5), (6, 'Lemon juice', '2', 'tbsp', 6),
(6, 'Olive oil', '0.25', 'cup', 7), (6, 'Egg yolk', '1', 'large', 8);

-- Seed recipe steps
INSERT INTO recipe_steps (recipe_id, step_number, instruction) VALUES
(1, 1, 'Preheat oven to 450F (230C). If using a pizza stone, place it in the oven.'),
(1, 2, 'Roll out pizza dough on a floured surface to desired thickness.'),
(1, 3, 'Crush San Marzano tomatoes and spread evenly over the dough.'),
(1, 4, 'Tear fresh mozzarella into pieces and distribute over the sauce.'),
(1, 5, 'Drizzle with olive oil and season with salt.'),
(1, 6, 'Bake for 12-15 minutes until crust is golden and cheese is bubbly.'),
(1, 7, 'Top with fresh basil leaves and serve immediately.'),
(2, 1, 'Cut chicken into bite-sized pieces and marinate in yogurt, garam masala, and salt for at least 30 minutes.'),
(2, 2, 'Thread chicken onto skewers and grill or broil until charred, about 8 minutes per side.'),
(2, 3, 'In a large pan, saute diced onion until golden, then add minced garlic and ginger.'),
(2, 4, 'Add tomato puree and cook for 10 minutes, stirring occasionally.'),
(2, 5, 'Stir in heavy cream and garam masala, simmer for 5 minutes.'),
(2, 6, 'Add grilled chicken pieces to the sauce and simmer for another 10 minutes.'),
(2, 7, 'Garnish with fresh cilantro and serve with basmati rice or naan bread.'),
(3, 1, 'Bring dashi stock to a gentle simmer in a medium saucepan.'),
(3, 2, 'Soak wakame seaweed in water for 5 minutes, then drain.'),
(3, 3, 'Cut silken tofu into small cubes.'),
(3, 4, 'Place miso paste in a small bowl, add a ladle of warm dashi, and whisk until smooth.'),
(3, 5, 'Add tofu and wakame to the simmering dashi.'),
(3, 6, 'Remove from heat and stir in the dissolved miso paste. Do not boil after adding miso.'),
(3, 7, 'Garnish with sliced green onion and serve immediately.'),
(4, 1, 'Season ground beef with cumin, chili powder, salt, and pepper.'),
(4, 2, 'Cook beef in a skillet over medium-high heat until browned, breaking it apart.'),
(4, 3, 'Warm corn tortillas on a dry skillet or directly over a gas flame.'),
(4, 4, 'Dice the white onion and chop fresh cilantro.'),
(4, 5, 'Assemble tacos by placing beef on tortillas and topping with onion and cilantro.'),
(4, 6, 'Serve with salsa verde and fresh lime wedges.'),
(5, 1, 'Preheat oven to 425F (220C). Butter and lightly flour four ramekins.'),
(5, 2, 'Melt dark chocolate and butter together in a double boiler or microwave.'),
(5, 3, 'In a bowl, whisk eggs, egg yolks, and sugar until thick and pale.'),
(5, 4, 'Fold the chocolate mixture into the egg mixture gently.'),
(5, 5, 'Fold in flour until just combined.'),
(5, 6, 'Divide batter among prepared ramekins.'),
(5, 7, 'Bake for exactly 12 minutes. The edges should be firm but the center soft.'),
(5, 8, 'Let cool for 1 minute, then invert onto plates and serve immediately.'),
(6, 1, 'Wash and dry romaine lettuce, then tear into bite-sized pieces.'),
(6, 2, 'For the dressing: mince anchovy fillets and garlic together into a paste.'),
(6, 3, 'Whisk together anchovy-garlic paste, egg yolk, lemon juice, and a pinch of salt.'),
(6, 4, 'Slowly drizzle in olive oil while whisking to create an emulsion.'),
(6, 5, 'Stir in half the grated parmesan cheese.'),
(6, 6, 'Toss lettuce with dressing until evenly coated.'),
(6, 7, 'Top with croutons and remaining shaved parmesan. Serve immediately.');

-- Seed ratings
INSERT INTO ratings (user_id, recipe_id, score) VALUES
(2, 3, 5), (2, 4, 4), (3, 1, 5), (3, 2, 4), (3, 5, 5), (1, 1, 4), (1, 4, 3)
ON CONFLICT (user_id, recipe_id) DO NOTHING;

-- Seed reviews
INSERT INTO reviews (user_id, recipe_id, comment) VALUES
(3, 1, 'Absolutely delicious! The fresh mozzarella makes all the difference.'),
(3, 2, 'Amazing flavor. I added a bit more cream for extra richness.'),
(2, 3, 'So simple and comforting. Perfect for a cold evening.'),
(3, 5, 'Best lava cake recipe I have tried. The center was perfectly molten!'),
(2, 4, 'Great weeknight dinner. Kids loved these tacos.');

-- Seed favorites
INSERT INTO favorites (user_id, recipe_id) VALUES
(2, 3), (2, 5), (3, 1), (3, 2), (3, 5), (1, 6)
ON CONFLICT (user_id, recipe_id) DO NOTHING;

-- Seed shopping list
INSERT INTO shopping_lists (user_id, name) VALUES (3, 'Weekly Groceries');
INSERT INTO shopping_list_items (shopping_list_id, ingredient_name, quantity, unit, recipe_id) VALUES
(1, 'Pizza dough', '1', 'ball', 1),
(1, 'Fresh mozzarella', '8', 'oz', 1),
(1, 'San Marzano tomatoes', '1', 'cup', 1),
(1, 'Ground beef', '1', 'lb', 4),
(1, 'Corn tortillas', '12', 'pieces', 4);
SEED_EOF

    echo "Seed data inserted successfully!"
else
    echo "Database already contains data (${USER_COUNT} users found). Skipping seed data."
fi

# Save connection command to a file
echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Save environment variables to a file
cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

echo "PostgreSQL setup complete!"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Port: ${DB_PORT}"
echo ""

echo "Environment variables saved to db_visualizer/postgres.env"
echo "To use with Node.js viewer, run: source db_visualizer/postgres.env"

echo "To connect to the database, use one of the following commands:"
echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
echo "$(cat db_connection.txt)"

echo ""
echo "=== Schema Summary ==="
echo "Tables: users, categories, cuisines, recipes, ingredients, recipe_steps,"
echo "        favorites, ratings, reviews, shopping_lists, shopping_list_items, moderation_log"
echo "The backend should connect using port 5001 (external proxy) or ${DB_PORT} (internal)."
