# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Godot 4.6 tower defense game with first-person player controls, written entirely in GDScript. Enemies follow procedurally-generated flow fields toward a central tower that auto-fires homing projectiles. The player can cast explosion (Q) and pull (E) abilities.

## Running the Project

Open in Godot 4.6 editor and run. Main scene: `res://scenes/node_3d.tscn`. Uses Jolt Physics engine (3D) with physics interpolation and threaded physics enabled.

## Architecture

**Entry point:** `scenes/node_3d.tscn` → `scripts/world.gd` — spawns all entities programmatically (terrain, player, enemies, tower, walls, environment). Almost nothing is pre-placed in scenes.

**Core scripts:**
- `scripts/terrain.gd` (859 lines) — Procedural terrain generation via FastNoiseLite, A* pathfinding with steepness cost, BFS flow fields, road network with Gaussian blending. Exposes `get_flow_direction()`, `get_height_at()`, `is_on_road()` for other systems.
- `scripts/world.gd` — World manager that initializes everything and sets up physics layers.
- `scripts/player_controller.gd` — CharacterBody3D FPS controller (WASD + mouse look + jump).
- `scripts/enemy.gd` — RigidBody3D enemies that follow terrain flow fields and respawn on goal reach.
- `scripts/tower.gd` — StaticBody3D turret, fires 3 projectiles per 0.5s at random enemies within range.
- `scripts/projectile.gd` — Area3D homing missiles using cubic Bézier curves with randomized control points.

**Collision layers:** 1=Ground, 2=Enemies, 3=Player

**Data structures:** Height maps, flow fields, and path distances are all 2D arrays indexed `[x][z]`.

**Communication pattern:** Direct references (e.g., enemies hold terrain reference). Minimal signal usage — mostly just `body_entered` for projectile hits.

## Conventions

- Terrain is the central data provider — other systems query it for height, flow direction, and road status.
- Entities are created via code in `world.gd`, not placed in the editor scene tree.
- Gravity is set to 19.6 (2x default) via ProjectSettings.
