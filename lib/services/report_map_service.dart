import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/report_summary.dart';

class ReportMapService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Stream<Set<Marker>> listenMarkers(
      Function(ReportSummary) onTap, {
        bool hanyaTitikRawan = false, // Tambahkan parameter ini
      }) {
    return _firestore
        .collection("reports")
        .where("status", whereNotIn: ["Dibatalkan", "Ditolak"])
        .snapshots()
        .map((snapshot) {

      var docs = snapshot.docs;

      // Jika mode titik rawan aktif, saring data dari Firebase
      if (hanyaTitikRawan) {
        docs = docs.where((doc) =>
        (doc.data()["status"] ?? "").toString().toLowerCase() == "diterima"
        ).toList();
      }

      return docs.map((doc) {
        final data = doc.data();
        final String status = (data["status"] ?? "").toString().toLowerCase();

        final summary = ReportSummary(
          id: doc.id,
          namaKejahatan: data["nama_kejahatan"] ?? "-",
          tempat: data["tempat"] ?? "-",
          status: data["status"] ?? "-",
          waktu: data["waktu"],
          posisi: LatLng(
            (data["latitude"] as num).toDouble(),
            (data["longitude"] as num).toDouble(),
          ),
        );

        final double markerHue = _getMarkerHue(status);

        return Marker(
          markerId: MarkerId(doc.id),
          position: summary.posisi,
          icon: BitmapDescriptor.defaultMarkerWithHue(markerHue),
          onTap: () => onTap(summary),
        );
      }).toSet();
    });
  }

  /// ===================== HELPER WARNA MARKER =====================
  double _getMarkerHue(String status) {
    switch (status) {
      case "diterima":
        return BitmapDescriptor.hueRed; // bahaya tinggi
      case "diajukan":
        return BitmapDescriptor.hueOrange; // masih proses
      default:
        return BitmapDescriptor.hueBlue; 
    }
  }
}
