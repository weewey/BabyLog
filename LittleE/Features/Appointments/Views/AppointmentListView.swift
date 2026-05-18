import SwiftUI
import LittleECore

struct AppointmentListView: View {

    let upcoming: [MedicalAppointment]
    let past: [MedicalAppointment]
    var onDelete: ((UUID) -> Void)? = nil

    var body: some View {
        if upcoming.isEmpty && past.isEmpty {
            Section {
                WarmEmptyState(
                    title: "No Appointments",
                    message: "Tap + to add a doctor visit, vaccination, or check-up.",
                    systemImage: "calendar",
                    tint: Theme.appointment
                )
                .accessibilityIdentifier("apptEmptyState")
                .frame(height: 220)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        } else {
            Group {
                if !upcoming.isEmpty {
                    Section("Upcoming") {
                        ForEach(upcoming) { appt in
                            AppointmentRow(appt: appt, isPast: false)
                                .accessibilityIdentifier("apptRow_\(appt.id)")
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        onDelete?(appt.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    .accessibilityIdentifier("deleteAppt_\(appt.id)")
                                }
                        }
                    }
                }
                if !past.isEmpty {
                    Section("Past") {
                        ForEach(past) { appt in
                            AppointmentRow(appt: appt, isPast: true)
                                .accessibilityIdentifier("apptRow_\(appt.id)")
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        onDelete?(appt.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
        }
    }
}

private struct AppointmentRow: View {
    let appt: MedicalAppointment
    let isPast: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(appt.title)
                    .font(.headline)
                    .foregroundStyle(isPast ? .secondary : .primary)
                Spacer()
                Badge(
                    systemImage: "calendar",
                    text: appt.scheduledAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()),
                    tint: isPast ? .gray : .indigo
                )
            }
            if let location = appt.location {
                Label(location, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let notes = appt.notes {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}
