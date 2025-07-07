# Full GUI + Optimized Gateway Planning Tool

import csv
import math
import simplekml
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
import os
import numpy as np
from sklearn.cluster import DBSCAN, KMeans
from sklearn.neighbors import BallTree
import threading

# Constants
EARTH_RADIUS = 6371000
MAX_RADIUS = 398  # meters
MIN_METERS = 20
IDEAL_MIN = 100
IDEAL_MAX = 150

class GatewayPlanner:
    def __init__(self, progress_callback=None):
        self.meters = []
        self.gateways = []
        self.progress_callback = progress_callback
        self.stop_processing = False

    def haversine_distance(self, lat1, lon1, lat2, lon2):
        phi1 = math.radians(lat1)
        phi2 = math.radians(lat2)
        d_phi = math.radians(lat2 - lat1)
        d_lambda = math.radians(lon2 - lon1)
        a = math.sin(d_phi / 2)**2 + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2)**2
        return EARTH_RADIUS * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))

    def load_meters_from_csv(self, filepath):
        self.meters = []
        try:
            with open(filepath, mode='r', encoding='utf-8-sig') as file:
                dialect = csv.Sniffer().sniff(file.read(1024))
                file.seek(0)
                reader = csv.DictReader(file, dialect=dialect)
                for row in reader:
                    if self.stop_processing:
                        return False
                    try:
                        row_lower = {k.strip().lower(): v for k, v in row.items()}
                        lat_key = next((k for k in row_lower.keys() if 'lat' in k), None)
                        lon_key = next((k for k in row_lower.keys() if 'lon' in k or 'long' in k), None)
                        if lat_key and lon_key:
                            lat = float(row_lower[lat_key])
                            lon = float(row_lower[lon_key])
                            if -90 <= lat <= 90 and -180 <= lon <= 180:
                                self.meters.append({
                                    'latitude': lat,
                                    'longitude': lon,
                                    'original_data': row
                                })
                    except (ValueError, TypeError):
                        continue
            return len(self.meters) > 0
        except Exception as e:
            print(f"CSV load error: {e}")
            return False

    def find_medoid(self, coords_rad):
        dists = np.sum(np.linalg.norm(coords_rad[:, None, :] - coords_rad[None, :, :], axis=2), axis=1)
        return np.argmin(dists)

    def run_gateway_planner(self):
        coords_deg = np.array([[m['latitude'], m['longitude']] for m in self.meters])
        coords_rad = np.radians(coords_deg)
        all_indices = np.arange(len(self.meters))
        assigned_indices = set()
        self.gateways = []

        def create_gateway(sub_indices):
            sub_coords_deg = coords_deg[sub_indices]
            sub_coords_rad = coords_rad[sub_indices]
            tree = BallTree(sub_coords_rad, metric='haversine')
            center_idx = self.find_medoid(sub_coords_rad)
            center_latlon = sub_coords_deg[center_idx]
            ind = tree.query_radius([np.radians(center_latlon)], r=MAX_RADIUS / EARTH_RADIUS)[0]
            covered = [self.meters[sub_indices[i]] for i in ind]
            real_indices = [sub_indices[i] for i in ind]
            return center_latlon, covered, real_indices

        db = DBSCAN(eps=MAX_RADIUS / EARTH_RADIUS, min_samples=MIN_METERS, metric='haversine')
        labels = db.fit_predict(coords_rad)

        for cluster_id in set(labels):
            if self.stop_processing:
                break
            if cluster_id == -1:
                continue
            cluster_indices = all_indices[labels == cluster_id]
            cluster_size = len(cluster_indices)
            k = math.ceil(cluster_size / IDEAL_MAX)
            if cluster_size > IDEAL_MAX:
                km = KMeans(n_clusters=k, random_state=42).fit(coords_deg[cluster_indices])
                for i in range(k):
                    sub_indices = cluster_indices[km.labels_ == i]
                    if len(sub_indices) < MIN_METERS:
                        continue
                    center_latlon, covered, real_indices = create_gateway(sub_indices)
                    if len(covered) >= MIN_METERS:
                        self.gateways.append({
                            'latitude': center_latlon[0],
                            'longitude': center_latlon[1],
                            'count': len(covered),
                            'meters': covered
                        })
                        assigned_indices.update(real_indices)
            else:
                center_latlon, covered, real_indices = create_gateway(cluster_indices)
                if len(covered) >= MIN_METERS:
                    self.gateways.append({
                        'latitude': center_latlon[0],
                        'longitude': center_latlon[1],
                        'count': len(covered),
                        'meters': covered
                    })
                    assigned_indices.update(real_indices)

        # Handle unassigned meters
        remaining_indices = list(set(all_indices) - assigned_indices)
        while len(remaining_indices) >= MIN_METERS:
            sub_coords_deg = coords_deg[remaining_indices]
            km = KMeans(n_clusters=1, random_state=42).fit(sub_coords_deg)
            sub_indices = np.array(remaining_indices)
            center_latlon, covered, real_indices = create_gateway(sub_indices)
            if len(covered) >= MIN_METERS:
                self.gateways.append({
                    'latitude': center_latlon[0],
                    'longitude': center_latlon[1],
                    'count': len(covered),
                    'meters': covered
                })
                for i in real_indices:
                    if i in remaining_indices:
                        remaining_indices.remove(i)
            else:
                break

    def generate_summary_csv(self, output_folder):
        path = os.path.join(output_folder, "gateway_summary.csv")
        with open(path, 'w', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            writer.writerow(['Gateway', 'Latitude', 'Longitude', 'Meters_Covered'])
            for i, g in enumerate(self.gateways, 1):
                writer.writerow([f"GW_{i}", g['latitude'], g['longitude'], g['count']])

    def generate_kml(self, output_folder):
        kml = simplekml.Kml()
        for i, g in enumerate(self.gateways, 1):
            p = kml.newpoint(name=f"GW {i} ({g['count']})", coords=[(g['longitude'], g['latitude'])])
            p.style.iconstyle.icon.href = "http://maps.google.com/mapfiles/kml/paddle/ylw-blank.png"
        kml.save(os.path.join(output_folder, "gateways.kml"))

class GatewayPlannerApp:
    def __init__(self, root):
        self.root = root
        self.root.title("Gateway Planner")
        self.planner = GatewayPlanner(self.update_progress)
        self.setup_ui()

    def setup_ui(self):
        frame = tk.Frame(self.root, padx=10, pady=10)
        frame.pack(fill=tk.BOTH, expand=True)

        tk.Label(frame, text="Meter CSV File").pack()
        self.csv_entry = tk.Entry(frame, width=60)
        self.csv_entry.pack()
        tk.Button(frame, text="Browse", command=self.browse_csv).pack()

        tk.Label(frame, text="Output Folder").pack()
        self.out_entry = tk.Entry(frame, width=60)
        self.out_entry.pack()
        tk.Button(frame, text="Browse", command=self.browse_output).pack()

        self.progress_label = tk.Label(frame, text="Status: Ready")
        self.progress_label.pack()
        self.progress_bar = ttk.Progressbar(frame, length=400)
        self.progress_bar.pack(pady=5)

        tk.Button(frame, text="Start Planning", command=self.start_processing).pack(pady=10)

    def browse_csv(self):
        path = filedialog.askopenfilename(filetypes=[("CSV Files", "*.csv")])
        if path:
            self.csv_entry.delete(0, tk.END)
            self.csv_entry.insert(0, path)

    def browse_output(self):
        folder = filedialog.askdirectory()
        if folder:
            self.out_entry.delete(0, tk.END)
            self.out_entry.insert(0, folder)

    def update_progress(self, msg, val):
        self.progress_label.config(text=msg)
        self.progress_bar["value"] = val
        self.root.update_idletasks()

    def start_processing(self):
        csv_file = self.csv_entry.get()
        out_folder = self.out_entry.get()
        if not csv_file or not out_folder:
            messagebox.showerror("Missing Info", "Please select input CSV and output folder")
            return

        def process():
            self.update_progress("Loading meters...", 10)
            if not self.planner.load_meters_from_csv(csv_file):
                messagebox.showerror("Error", "Failed to load meter data.")
                return
            self.update_progress("Planning gateways...", 40)
            self.planner.run_gateway_planner()
            self.update_progress("Saving files...", 80)
            self.planner.generate_summary_csv(out_folder)
            self.planner.generate_kml(out_folder)
            self.update_progress("Done!", 100)
            messagebox.showinfo("Complete", f"Gateways planned: {len(self.planner.gateways)}")

        threading.Thread(target=process, daemon=True).start()

if __name__ == "__main__":
    root = tk.Tk()
    app = GatewayPlannerApp(root)
    root.mainloop()
